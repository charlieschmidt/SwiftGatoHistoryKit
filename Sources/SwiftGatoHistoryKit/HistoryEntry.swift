import Foundation

/// One historical sample decoded from an accessory's Eve/fakegato-history log.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public let timestamp: Date
    public var temperatureCelsius: Double?
    public var humidityPercent: Double?
    public var co2PPM: Double?

    public init(timestamp: Date, temperatureCelsius: Double? = nil, humidityPercent: Double? = nil, co2PPM: Double? = nil) {
        self.timestamp = timestamp
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.co2PPM = co2PPM
    }
}

/// Result of one history fetch. Persist `lastSyncedAddress` as the
/// accessory's resume cursor for the next sync.
public struct HistoryFetchResult: Sendable {
    public let entries: [HistoryEntry]
    /// Newest address seen in this fetch, across every record processed —
    /// not just the ones that decoded into a `HistoryEntry` (see
    /// `FakegatoHistoryDecoder.parseEntries(_:referenceDate:)`). `nil` if
    /// nothing was fetched; leave any stored cursor untouched in that case.
    public let lastSyncedAddress: UInt32?

    public init(entries: [HistoryEntry], lastSyncedAddress: UInt32?) {
        self.entries = entries
        self.lastSyncedAddress = lastSyncedAddress
    }
}

/// Progress through a sync pipeline (request → download → import), possibly
/// spanning multiple accessories, so UI can show a progress bar and status
/// line instead of looking hung during a long history download.
///
/// This type is for a consumer's orchestration layer. The decoder/drainer
/// in this package only report raw `(current, total)` ints; mapping those
/// into phases below is the consumer's job.
public struct HistorySyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Requesting an accessory's history. Indeterminate — covers the
        /// window before the Status characteristic reports a total count
        /// and this moves to `.downloading`.
        case searching
        /// Streaming entries from the accessory. `total` is that
        /// accessory's own reported entry count (everything retained, not
        /// just what's new).
        case downloading(current: Int, total: Int)
        /// Writing persisted rows for entries newer than what's already
        /// stored. `total` is the combined new-entry count across every
        /// accessory in this sync, so progress doesn't restart per accessory.
        case importing(current: Int, total: Int)
    }

    public var phase: Phase
    /// Name of the accessory currently being fetched/imported, for the
    /// status line. `nil` if no name could be resolved.
    public var accessoryName: String?

    public init(phase: Phase, accessoryName: String? = nil) {
        self.phase = phase
        self.accessoryName = accessoryName
    }
}
