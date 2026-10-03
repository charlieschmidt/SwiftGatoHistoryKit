import Foundation
import os

public enum FakegatoHistoryDrainer {

    /// Outcome of `drainEntries(status:accessoryName:maxIterations:logger:readNext:onProgress:)`:
    /// every entry decoded before the drain stopped, the highest
    /// ring-buffer address seen across every batch read (for the next
    /// resume cursor), and why the drain stopped.
    public struct DrainResult: Equatable, Sendable {
        /// Every entry successfully decoded before the drain stopped.
        public let entries: [HistoryEntry]
        /// The highest entry address seen across every batch read —
        /// including a batch that decoded to zero `HistoryEntry` values,
        /// see `DrainStopReason.noDecodableEntries` — or `nil` if no batch
        /// ever produced one. Intended to be persisted as the next fetch's
        /// resume cursor.
        public let lastAddress: UInt32?
        /// Why the drain loop stopped.
        public let stopReason: DrainStopReason
    }

    /// The distinct ways `drainEntries` can stop reading. A sibling of
    /// `DrainResult` (rather than nested inside it) to keep type nesting to
    /// one level.
    public enum DrainStopReason: Equatable, Sendable {
        /// `status.usedEntryCount` entries have now been collected.
        case countReached
        /// The enclosing `Task` was cancelled.
        case cancelled
        /// `readNext()` threw.
        case readFailed
        /// `readNext()` returned `nil` or empty `Data`.
        case emptyRead
        /// A read returned byte-for-byte identical data to the immediately
        /// previous read — the accessory isn't advancing.
        case identicalBytes
        /// A read batch had zero parseable records at all (`recordCount
        /// == 0` — the accessory sent no records this read, not even
        /// unsupported ones). A batch with ≥1 record but zero decoded
        /// `HistoryEntry` values (e.g. all-unsupported types) does *not*
        /// hit this case — the drain keeps reading, since `lastAddress`
        /// genuinely advanced and there may be decodable entries further
        /// along.
        case noDecodableEntries
        /// The defensive `maxIterations` safety cap was hit.
        case iterationCap
    }

    /// Repeatedly calls `readNext()` until `status.usedEntryCount` is
    /// reached, a read comes back with nothing new, or `maxIterations` is
    /// hit. A pure function of its arguments (no HomeKit types) so the
    /// polling/decoding loop is testable against a scripted `readNext`
    /// without a live Home — see `FakegatoHistoryDrainerTests`. `readNext`
    /// stands in for reading a characteristic's current value; the real
    /// caller passes exactly that.
    ///
    /// Also tracks the highest entry address seen across every batch
    /// (regardless of `startingAtAddress`, since `status.usedEntryCount` is
    /// the accessory's *total* retained count, not the count remaining from
    /// a resumed address; the natural "count reached" stop condition above
    /// effectively only fires on a full fetch; a resumed fetch stops via
    /// "nothing new" or the identical-bytes guard instead, both handled
    /// identically here), so the caller can persist it as the next resume
    /// cursor. This advances even when an entire batch fails to decode into
    /// any `HistoryEntry`; a record with an unsupported/malformed type
    /// still occupies one address slot in the accessory's ring buffer, so
    /// the cursor must advance past it too, matching
    /// `FakegatoHistoryDecoder.parseEntries(_:referenceDate:)`'s own
    /// `lastAddress` semantics.
    public static func drainEntries(
        status: FakegatoHistoryDecoder.HistoryStatus,
        accessoryName: String,
        maxIterations: Int = 5000,
        logger: Logger? = nil,
        readNext: () async throws -> Data?,
        onProgress: ((_ current: Int, _ total: Int) -> Void)?
    ) async -> DrainResult {
        var referenceDate = status.referenceDate
        var entries: [HistoryEntry] = []
        var lastAddress: UInt32?
        var iterations = 0
        var previousEntriesData: Data?
        var breakReason: DrainStopReason?

        while entries.count < status.usedEntryCount, iterations < maxIterations {
            if Task.isCancelled {
                breakReason = .cancelled
                break
            }
            iterations += 1

            let entriesData: Data?
            do {
                entriesData = try await readNext()
            } catch {
                // Non-fatal: log and stop, returning whatever was
                // successfully collected before this read failed, rather
                // than discarding an otherwise-successful partial fetch.
                logger?.error("fetchHistory: reading Entries characteristic on \"\(accessoryName, privacy: .public)\" failed on iteration \(iterations, privacy: .public): \(error, privacy: .public). Stopping with \(entries.count, privacy: .public) entries collected.")
                breakReason = .readFailed
                break
            }

            guard let entriesData, !entriesData.isEmpty else {
                breakReason = .emptyRead
                break
            }

            // Defensive guard against an accessory that doesn't advance its
            // internal read cursor between characteristic reads — the
            // reverse-engineered protocol docs are explicitly unclear on
            // whether every accessory does. Without this, an accessory
            // that just keeps returning the same bytes would spin all the
            // way to `maxIterations`, decoding (and appending) the same
            // entries over and over.
            if entriesData == previousEntriesData {
                logger?.error("fetchHistory: iteration \(iterations, privacy: .public) on \"\(accessoryName, privacy: .public)\" returned identical bytes to the previous read — accessory isn't advancing. Stopping with \(entries.count, privacy: .public) entries collected.")
                breakReason = .identicalBytes
                break
            }
            previousEntriesData = entriesData

            let batch = FakegatoHistoryDecoder.parseEntries(entriesData, referenceDate: referenceDate)
            lastAddress = batch.lastAddress ?? lastAddress
            // `recordCount == 0` means this read truly had nothing
            // parseable — genuine end-of-stream. A batch with records that
            // all happened to be unsupported types still made progress
            // (`lastAddress` advanced above), so keep reading rather than
            // stopping on `batch.entries.isEmpty` alone.
            guard batch.recordCount > 0 else {
                breakReason = .noDecodableEntries
                break
            }
            entries.append(contentsOf: batch.entries)
            referenceDate = batch.referenceDate
            onProgress?(entries.count, status.usedEntryCount)
        }

        if iterations >= maxIterations {
            logger?.error("fetchHistory: hit the \(maxIterations, privacy: .public)-iteration safety cap on \"\(accessoryName, privacy: .public)\" with \(entries.count, privacy: .public) of \(status.usedEntryCount, privacy: .public) expected entries collected.")
        }

        let stopReason = breakReason ?? (entries.count >= status.usedEntryCount ? .countReached : .iterationCap)
        return DrainResult(entries: entries, lastAddress: lastAddress, stopReason: stopReason)
    }
}
