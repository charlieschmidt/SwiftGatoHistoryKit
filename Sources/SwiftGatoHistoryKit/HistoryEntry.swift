import Foundation

/// One historical sample from an accessory's own on-device log, decoded
/// from Eve/fakegato-history.
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

/// Result of one history fetch — a consumer persists `lastSyncedAddress`
/// as the accessory's resume cursor for the next sync.
public struct HistoryFetchResult: Sendable {
    public let entries: [HistoryEntry]
    /// Address of the newest entry this fetch actually saw (across every
    /// record processed, not just ones that decoded into a `HistoryEntry`
    /// — see `FakegatoHistoryDecoder.parseEntries(_:referenceDate:)`).
    /// `nil` if nothing was fetched, in which case the caller should leave
    /// any previously-stored cursor untouched rather than clearing it.
    public let lastSyncedAddress: UInt32?

    public init(entries: [HistoryEntry], lastSyncedAddress: UInt32?) {
        self.entries = entries
        self.lastSyncedAddress = lastSyncedAddress
    }
}

/// Progress through a sync-orchestration pipeline (request → download →
/// import) that spans potentially multiple accessories, so UI can show a
/// spinner/progress bar plus a status line instead of looking hung —
/// downloading years of history from a real accessory can take a while.
///
/// This type is shipped for a consumer's orchestration layer to use; the
/// decoder/drainer in this package never produce it themselves — they
/// report raw `(current, total)` ints, and it's the consumer's job to map
/// those into phases like `.downloading`/`.importing` below.
public struct HistorySyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Requesting an accessory's history — indeterminate, covering the
        /// brief window between writing the request and getting back its
        /// Status characteristic (which is when the total entry count
        /// becomes known and this moves to `.downloading`).
        case searching
        /// Streaming entries from the accessory. `total` is that
        /// accessory's own reported entry count (everything it retains,
        /// not just what's new) — `current == 0` reads naturally as "found
        /// `total` entries, starting download."
        case downloading(current: Int, total: Int)
        /// Writing persisted rows for entries newer than what's already
        /// stored. `total` is the combined new-entry count across every
        /// accessory being synced, so a multi-accessory sync shows one
        /// continuous progress bar rather than restarting per accessory.
        case importing(current: Int, total: Int)
    }

    public var phase: Phase
    /// Display name of the accessory currently being fetched/imported, for
    /// the status line — `nil` if no name could be resolved.
    public var accessoryName: String?

    public init(phase: Phase, accessoryName: String? = nil) {
        self.phase = phase
        self.accessoryName = accessoryName
    }
}
