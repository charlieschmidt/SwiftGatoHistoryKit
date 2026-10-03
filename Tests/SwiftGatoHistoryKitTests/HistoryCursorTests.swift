import Testing
import Foundation
@testable import SwiftGatoHistoryKit

/// `isStale(startingAtAddress:status:)` decides whether the next address a
/// caller is about to request still falls within an accessory's currently
/// retained history range — see `HistoryCursor`'s doc comment for why a
/// stale cursor must fall back to a full re-fetch rather than risk silently
/// missing entries. It's a pure function of `startingAtAddress` and
/// `status` (no HomeKit types), so it's directly testable without a live
/// home.
///
/// The valid (non-stale) range is `firstEntryAddress` through
/// `firstEntryAddress + usedEntryCount + 1` inclusive — the `+ 1` upper
/// bound is the "resume right after the newest entry, nothing new logged
/// yet" case a fully caught-up accessory hits on every subsequent sync.
/// Flagging that specific address as stale was a real regression: it
/// forced a full ~4,000-entry re-download on every sync/launch where
/// nothing new had happened, defeating the resume cursor's entire purpose.
struct HistoryCursorTests {

    private func status(firstEntryAddress: UInt32, usedEntryCount: Int) -> FakegatoHistoryDecoder.HistoryStatus {
        FakegatoHistoryDecoder.HistoryStatus(
            referenceDate: .distantPast,
            usedEntryCount: usedEntryCount,
            memorySize: 4096,
            firstEntryAddress: firstEntryAddress
        )
    }

    @Test func cursorOlderThanFirstEntryAddressIsStale() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 50)
        #expect(HistoryCursor.isStale(startingAtAddress: 99, status: status))
    }

    @Test func cursorEqualToFirstEntryAddressIsFresh() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 50)
        #expect(!HistoryCursor.isStale(startingAtAddress: 100, status: status))
    }

    @Test func cursorEqualToNewestKnownAddressIsFresh() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 50)
        #expect(!HistoryCursor.isStale(startingAtAddress: 150, status: status))
    }

    /// The regression case: resuming exactly one past the newest known
    /// entry (`firstEntryAddress + usedEntryCount + 1`) means "nothing new
    /// since last sync", not "stale". Getting this wrong is what forced a
    /// full re-download on every fully-caught-up sync.
    @Test func cursorOnePastNewestKnownAddressIsFresh() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 50)
        #expect(!HistoryCursor.isStale(startingAtAddress: 151, status: status))
    }

    @Test func cursorTwoPastNewestKnownAddressIsStale() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 50)
        #expect(HistoryCursor.isStale(startingAtAddress: 152, status: status))
    }

    @Test func zeroUsedEntryCountBoundaryIsFresh() {
        let status = status(firstEntryAddress: 100, usedEntryCount: 0)
        #expect(!HistoryCursor.isStale(startingAtAddress: 100, status: status))
        #expect(!HistoryCursor.isStale(startingAtAddress: 101, status: status))
        #expect(HistoryCursor.isStale(startingAtAddress: 102, status: status))
    }

    /// A corrupted/crafted `firstEntryAddress`/`usedEntryCount` pair whose
    /// "one past newest" upper bound would overflow `UInt32` must report
    /// stale (forcing a safe full re-fetch) rather than trapping — this
    /// also guards the log message that used to recompute this same sum
    /// with a plain, trapping `+`.
    @Test func overflowingUpperBoundIsStale() {
        let status = status(firstEntryAddress: .max, usedEntryCount: 1)
        #expect(HistoryCursor.isStale(startingAtAddress: .max, status: status))
        #expect(HistoryCursor.retainedRangeUpperBound(status: status) == nil)
    }

    /// A first-ever sync (no persisted cursor) requests address `1`. A
    /// caller must run that through `isStale` like any other address —
    /// there used to be a `startingAtAddress > 1` short-circuit that
    /// skipped the check, so a first sync against a ring buffer that had
    /// already wrapped streamed from physical slot `1 % memorySize` with
    /// relabelled addresses. These pin down what `isStale` says about `1`
    /// in each state so that short-circuit can't come back as a
    /// "harmless" optimisation.
    @Test func addressOneIsStaleOnAWrappedRingButFreshOnAnUnwrappedOne() {
        // Wrapped: fakegato reports the oldest retained address (7498 here,
        // from the real-device fixture) — `1` was evicted long ago.
        let wrapped = status(firstEntryAddress: 7498, usedEntryCount: 4031)
        #expect(HistoryCursor.isStale(startingAtAddress: 1, status: wrapped))

        // Not yet wrapped: fakegato reports `firstEntry == 0`, and records
        // live at `1...usedEntryCount`, so `1` is exactly the oldest one.
        let fresh = status(firstEntryAddress: 0, usedEntryCount: 50)
        #expect(!HistoryCursor.isStale(startingAtAddress: 1, status: fresh))
        // ...and the caught-up resume address (one past newest) stays fresh.
        #expect(!HistoryCursor.isStale(startingAtAddress: 51, status: fresh))
        #expect(HistoryCursor.isStale(startingAtAddress: 52, status: fresh))
    }

    /// On an un-wrapped ring the fallback address is fakegato's raw
    /// `firstEntry` field, `0` — which the protocol defines as "restart
    /// from the beginning" (`sendHistory(0)` → entry `1`), so it's a valid
    /// restart point, not a bug.
    @Test func staleCursorFallbackOnAnUnwrappedRingIsAddressZero() {
        let fresh = status(firstEntryAddress: 0, usedEntryCount: 50)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: fresh) == 0)
    }

    /// Once a cursor is flagged stale, a full re-fetch must restart from
    /// the accessory's own `firstEntryAddress`, never a hardcoded `1` — on
    /// a wrapped ring (like this real-device case: 4031 entries, oldest
    /// retained at 7498), address `1` no longer exists, so re-requesting it
    /// would relabel whatever slot the accessory streams first as address
    /// `1` onward, corrupting every subsequent entry's address.
    @Test func staleCursorFallbackRestartsFromTheAccessorysFirstEntryAddressNotOne() {
        let status = status(firstEntryAddress: 7498, usedEntryCount: 4031)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: status) == 7498)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: status) != 1)
    }
}
