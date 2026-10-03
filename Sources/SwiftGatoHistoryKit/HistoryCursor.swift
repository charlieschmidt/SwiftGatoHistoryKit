import Foundation

/// Pure staleness math for an accessory's history resume cursor against
/// its currently retained Status range.
public enum HistoryCursor {

    /// Whether `startingAtAddress` (the next address a caller is about to
    /// request — a previously-persisted resume cursor plus one) no longer
    /// falls within `status`'s currently retained range — either older
    /// than the oldest retained entry (the ring buffer wrapped past it) or
    /// newer than one-past the accessory's own newest known entry (e.g.
    /// the accessory was reset).
    ///
    /// The valid (non-stale) range is `firstEntryAddress` through
    /// `firstEntryAddress + usedEntryCount + 1` *inclusive* — the `+ 1` is
    /// deliberate, not an off-by-one: a fully caught-up accessory's next
    /// request naturally resumes right after the newest known entry
    /// (`firstEntryAddress + usedEntryCount + 1`), and that's healthy, not
    /// stale, whenever nothing new has been logged since the last sync.
    /// Flagging that address as stale forces a full re-download of the
    /// entire ring buffer on every sync/launch where nothing new had
    /// happened, defeating the resume cursor's purpose.
    ///
    /// The upper-bound addition is guarded with `addingReportingOverflow`
    /// rather than plain `+`; on overflow this reports stale, since the
    /// safe failure mode here is an unnecessary full re-fetch, never a
    /// silently-missed range.
    public static func isStale(startingAtAddress: UInt32, status: FakegatoHistoryDecoder.HistoryStatus) -> Bool {
        if startingAtAddress < status.firstEntryAddress {
            return true
        }
        guard let upperBound = retainedRangeUpperBound(status: status) else {
            return true // Overflow — the safe direction is an unnecessary full re-fetch.
        }
        return startingAtAddress > upperBound
    }

    /// One-past-the-newest-known address in `status`'s currently retained
    /// range (`firstEntryAddress + usedEntryCount + 1`), or `nil` if that
    /// computation would overflow `UInt32` — e.g. a corrupted/crafted
    /// `status` pair. Guarded with `addingReportingOverflow` rather than
    /// plain `+` so neither `isStale` nor a caller's log message can trap
    /// on such a value. Shared so both use the exact same overflow-safe
    /// arithmetic.
    public static func retainedRangeUpperBound(status: FakegatoHistoryDecoder.HistoryStatus) -> UInt32? {
        let (newestKnown, newestOverflowed) = status.firstEntryAddress.addingReportingOverflow(UInt32(status.usedEntryCount))
        guard !newestOverflowed else { return nil }
        let (upperBound, upperOverflowed) = newestKnown.addingReportingOverflow(1)
        guard !upperOverflowed else { return nil }
        return upperBound
    }

    /// The address a stale-cursor full re-fetch should restart from — the
    /// Status characteristic's own `firstEntryAddress`, never a hardcoded
    /// `1`. On a ring that has wrapped, address `1` no longer exists;
    /// re-requesting it would just relabel whatever slot the accessory
    /// streams first as address `1` onward, corrupting every subsequent
    /// entry's address rather than fixing the staleness. On a ring that
    /// *hasn't* wrapped, `firstEntryAddress` is `0`, which the protocol
    /// defines as "restart from the beginning" (fakegato's `sendHistory`
    /// maps it to entry `1`) — so it's the right answer in both states,
    /// not just the wrapped one.
    public static func staleCursorFallbackAddress(status: FakegatoHistoryDecoder.HistoryStatus) -> UInt32 {
        status.firstEntryAddress
    }
}
