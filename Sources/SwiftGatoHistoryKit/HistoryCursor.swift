import Foundation

/// Pure staleness math for an accessory's history resume cursor against
/// its currently retained Status range.
public enum HistoryCursor {

    /// Whether `startingAtAddress` (a persisted resume cursor plus one) has
    /// fallen outside `status`'s currently retained range — either older
    /// than the oldest retained entry (the ring buffer wrapped past it) or
    /// newer than one-past the newest known entry (e.g. the accessory was
    /// reset).
    ///
    /// The valid range is `firstEntryAddress` through
    /// `firstEntryAddress + usedEntryCount + 1` inclusive. That `+ 1` isn't
    /// an off-by-one: a fully caught-up accessory's next request naturally
    /// lands there, and that's healthy, not stale — flagging it as stale
    /// would force a full re-download every sync where nothing new had
    /// been logged.
    ///
    /// The upper bound is computed with `addingReportingOverflow` rather
    /// than plain `+`; on overflow this reports stale, since an unnecessary
    /// re-fetch is a safer failure than a silently-missed range.
    public static func isStale(startingAtAddress: UInt32, status: FakegatoHistoryDecoder.HistoryStatus) -> Bool {
        if startingAtAddress < status.firstEntryAddress {
            return true
        }
        guard let upperBound = retainedRangeUpperBound(status: status) else {
            return true // overflow — safer to over-fetch than under-fetch
        }
        return startingAtAddress > upperBound
    }

    /// One past the newest known address in `status`'s retained range
    /// (`firstEntryAddress + usedEntryCount + 1`), or `nil` if that would
    /// overflow `UInt32` (e.g. a corrupted `status` pair). Exposed so
    /// `isStale` and callers' log messages share the same overflow-safe
    /// arithmetic instead of each re-deriving it with plain `+`.
    public static func retainedRangeUpperBound(status: FakegatoHistoryDecoder.HistoryStatus) -> UInt32? {
        let (newestKnown, newestOverflowed) = status.firstEntryAddress.addingReportingOverflow(UInt32(status.usedEntryCount))
        guard !newestOverflowed else { return nil }
        let (upperBound, upperOverflowed) = newestKnown.addingReportingOverflow(1)
        guard !upperOverflowed else { return nil }
        return upperBound
    }

    /// Where a stale-cursor re-fetch should restart from: the Status
    /// characteristic's own `firstEntryAddress`, never a hardcoded `1`.
    /// On a wrapped ring, address `1` no longer exists — re-requesting it
    /// would just relabel whatever the accessory streams first as `1`
    /// onward, corrupting every later address. On an unwrapped ring,
    /// `firstEntryAddress` is `0`, which the protocol already defines as
    /// "restart from the beginning" (fakegato's `sendHistory` maps it to
    /// entry `1`), so this works in both states.
    public static func staleCursorFallbackAddress(status: FakegatoHistoryDecoder.HistoryStatus) -> UInt32 {
        status.firstEntryAddress
    }
}
