import Foundation
import os

public enum FakegatoHistoryDrainer {

    /// Outcome of `drainEntries`: the decoded entries, the highest
    /// ring-buffer address seen (for the next resume cursor), and why the
    /// drain stopped.
    public struct DrainResult: Equatable, Sendable {
        /// Every entry successfully decoded before the drain stopped.
        public let entries: [HistoryEntry]
        /// The highest entry address seen across every batch read, even a
        /// batch that decoded to zero entries (see
        /// `DrainStopReason.noDecodableEntries`). `nil` if no batch ever
        /// produced one. Persist this as the next fetch's resume cursor.
        public let lastAddress: UInt32?
        /// Why the drain loop stopped.
        public let stopReason: DrainStopReason
    }

    /// The ways `drainEntries` can stop reading. A sibling of `DrainResult`
    /// rather than nested inside it, to keep type nesting to one level.
    public enum DrainStopReason: Equatable, Sendable {
        /// `status.usedEntryCount` entries have now been collected.
        case countReached
        /// The enclosing `Task` was cancelled.
        case cancelled
        /// `readNext()` threw.
        case readFailed
        /// `readNext()` returned `nil` or empty `Data`.
        case emptyRead
        /// A read returned byte-for-byte identical data to the previous
        /// one — the accessory isn't advancing.
        case identicalBytes
        /// A read batch had zero parseable records (`recordCount == 0`) —
        /// genuine end-of-stream. A batch with records that all happen to
        /// be unsupported types doesn't hit this case; `lastAddress` still
        /// advanced, so the drain keeps reading in case decodable entries
        /// follow.
        case noDecodableEntries
        /// The defensive `maxIterations` safety cap was hit.
        case iterationCap
    }

    /// Repeatedly calls `readNext()` until `status.usedEntryCount` is
    /// reached, a read comes back with nothing new, or `maxIterations` is
    /// hit. A pure function of its arguments (no HomeKit types), so the
    /// polling/decoding loop is testable against a scripted `readNext`
    /// without a live Home — see `FakegatoHistoryDrainerTests`. `readNext`
    /// stands in for reading a characteristic's current value.
    ///
    /// Also tracks the highest entry address seen across every batch, so
    /// the caller can persist it as the next resume cursor. This advances
    /// even when a whole batch fails to decode into any `HistoryEntry`: an
    /// unsupported or malformed record still occupies an address slot in
    /// the accessory's ring buffer, so the cursor has to move past it too,
    /// matching `FakegatoHistoryDecoder.parseEntries(_:referenceDate:)`'s
    /// own `lastAddress` semantics. (`status.usedEntryCount` is the
    /// accessory's total retained count, not what's left from a resumed
    /// address, so "count reached" mainly fires on a full fetch; a resumed
    /// fetch usually stops via "nothing new" or the identical-bytes guard
    /// instead.)
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
                // Non-fatal: stop and return whatever was already collected
                // rather than discard a partial fetch.
                logger?.error("fetchHistory: reading Entries characteristic on \"\(accessoryName, privacy: .public)\" failed on iteration \(iterations, privacy: .public): \(error, privacy: .public). Stopping with \(entries.count, privacy: .public) entries collected.")
                breakReason = .readFailed
                break
            }

            guard let entriesData, !entriesData.isEmpty else {
                breakReason = .emptyRead
                break
            }

            // Guards against an accessory that doesn't advance its read
            // cursor between reads (the protocol docs don't guarantee it
            // does). Without this, repeated identical bytes would spin to
            // `maxIterations`, re-decoding the same entries each time.
            if entriesData == previousEntriesData {
                logger?.error("fetchHistory: iteration \(iterations, privacy: .public) on \"\(accessoryName, privacy: .public)\" returned identical bytes to the previous read — accessory isn't advancing. Stopping with \(entries.count, privacy: .public) entries collected.")
                breakReason = .identicalBytes
                break
            }
            previousEntriesData = entriesData

            let batch = FakegatoHistoryDecoder.parseEntries(entriesData, referenceDate: referenceDate)
            lastAddress = batch.lastAddress ?? lastAddress
            // `recordCount == 0` is genuine end-of-stream. A batch of
            // all-unsupported types still advanced `lastAddress`, so keep
            // reading rather than stop on `batch.entries.isEmpty` alone.
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
