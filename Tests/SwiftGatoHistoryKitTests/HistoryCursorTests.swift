import Testing
import Foundation
@testable import SwiftGatoHistoryKit

/// `isStale(startingAtAddress:status:)` decides whether the next address a
/// caller is about to request still falls within an accessory's retained
/// history range — see `HistoryCursor`'s doc comment for why a stale
/// cursor falls back to a full re-fetch rather than risking missed
/// entries. It's a pure function, so it's directly testable without a
/// live home.
///
/// The valid range is `firstEntryAddress` through `firstEntryAddress +
/// usedEntryCount + 1` inclusive. That `+ 1` upper bound covers "resumed
/// right after the newest entry, nothing new logged yet" — a fully
/// caught-up accessory hits this on every sync. Flagging that address as
/// stale was a real regression: it forced a full ~4,000-entry re-download
/// on every sync where nothing new had happened.
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
    /// entry means "nothing new since last sync," not "stale."
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

    /// A corrupted `firstEntryAddress`/`usedEntryCount` pair whose "one
    /// past newest" sum would overflow `UInt32` must report stale rather
    /// than trap.
    @Test func overflowingUpperBoundIsStale() {
        let status = status(firstEntryAddress: .max, usedEntryCount: 1)
        #expect(HistoryCursor.isStale(startingAtAddress: .max, status: status))
        #expect(HistoryCursor.retainedRangeUpperBound(status: status) == nil)
    }

    /// A first-ever sync (no persisted cursor) requests address `1`, which
    /// must run through `isStale` like any other address — there used to
    /// be a `startingAtAddress > 1` short-circuit that skipped the check,
    /// so a first sync against an already-wrapped ring streamed from the
    /// wrong physical slot with relabelled addresses. These pin down what
    /// `isStale` says about `1` in each state so that short-circuit can't
    /// come back.
    @Test func addressOneIsStaleOnAWrappedRingButFreshOnAnUnwrappedOne() {
        // Wrapped: oldest retained address is 7498 (real-device fixture) — `1` was evicted long ago.
        let wrapped = status(firstEntryAddress: 7498, usedEntryCount: 4031)
        #expect(HistoryCursor.isStale(startingAtAddress: 1, status: wrapped))

        // Not yet wrapped: records live at `1...usedEntryCount`, so `1` is the oldest one.
        let fresh = status(firstEntryAddress: 0, usedEntryCount: 50)
        #expect(!HistoryCursor.isStale(startingAtAddress: 1, status: fresh))
        // Caught-up resume address (one past newest) stays fresh too.
        #expect(!HistoryCursor.isStale(startingAtAddress: 51, status: fresh))
        #expect(HistoryCursor.isStale(startingAtAddress: 52, status: fresh))
    }

    /// On an un-wrapped ring the fallback address is `0`, fakegato's raw
    /// `firstEntry` field — a valid restart point, not a bug.
    @Test func staleCursorFallbackOnAnUnwrappedRingIsAddressZero() {
        let fresh = status(firstEntryAddress: 0, usedEntryCount: 50)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: fresh) == 0)
    }

    /// A stale cursor must restart from the accessory's own
    /// `firstEntryAddress`, never a hardcoded `1` — on this wrapped ring,
    /// address `1` no longer exists.
    @Test func staleCursorFallbackRestartsFromTheAccessorysFirstEntryAddressNotOne() {
        let status = status(firstEntryAddress: 7498, usedEntryCount: 4031)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: status) == 7498)
        #expect(HistoryCursor.staleCursorFallbackAddress(status: status) != 1)
    }
}
