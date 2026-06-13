@testable import ConvosCore
import Foundation
import Testing

@Suite("InviteJoinRequestsManager Tests")
struct InviteJoinRequestsManagerTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let day: TimeInterval = 24 * 60 * 60

    @Test("Nil cursor clamps to the 24h window instead of sweeping all history")
    func nilCursorClampsToWindow() {
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: nil, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Recent cursor passes through unchanged")
    func recentCursorUnchanged() {
        let recent = now.addingTimeInterval(-300)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: recent, now: now)
        #expect(effective == recent)
    }

    @Test("Cursor older than the window clamps to the window")
    func ancientCursorClamps() {
        let ancient = now.addingTimeInterval(-90 * day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: ancient, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Cursor exactly at the window boundary is preserved")
    func boundaryCursorPreserved() {
        let boundary = now.addingTimeInterval(-day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: boundary, now: now)
        #expect(effective == boundary)
    }
}
