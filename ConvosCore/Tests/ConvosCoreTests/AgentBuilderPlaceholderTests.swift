@testable import ConvosCore
import Foundation
import Testing

/// Coverage for `AgentBuilderPlaceholder` - the time-box that stops the
/// optimistic "verified agent joining" placeholder from lingering forever
/// when an agent joins but never publishes attestation.
@Suite("AgentBuilderPlaceholder Tests")
struct AgentBuilderPlaceholderTests {
    @Test("Freshly committed summary has ~full window remaining")
    func freshCommitHasFullWindow() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let now = cutoff
        let remaining = AgentBuilderPlaceholder.remainingDisplayTime(since: cutoff, now: now)
        #expect(remaining == AgentBuilderPlaceholder.displayDuration)
    }

    @Test("Partway through the window leaves the expected remainder")
    func partwayLeavesRemainder() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let now = cutoff.addingTimeInterval(20)
        let remaining = AgentBuilderPlaceholder.remainingDisplayTime(since: cutoff, now: now)
        #expect(remaining == AgentBuilderPlaceholder.displayDuration - 20)
        #expect(remaining > 0)
    }

    @Test("A commit older than the window has already expired")
    func oldCommitIsExpired() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let now = cutoff.addingTimeInterval(AgentBuilderPlaceholder.displayDuration + 1)
        let remaining = AgentBuilderPlaceholder.remainingDisplayTime(since: cutoff, now: now)
        #expect(remaining < 0)
    }

    @Test("Exactly at the boundary is treated as elapsed")
    func boundaryIsElapsed() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let now = cutoff.addingTimeInterval(AgentBuilderPlaceholder.displayDuration)
        let remaining = AgentBuilderPlaceholder.remainingDisplayTime(since: cutoff, now: now)
        // remaining == 0 -> the scheduler treats `> 0` as "still showing", so
        // zero means expire now.
        #expect(remaining == 0)
        #expect(!(remaining > 0))
    }
}
