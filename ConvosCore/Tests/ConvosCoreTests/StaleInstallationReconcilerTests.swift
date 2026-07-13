@testable import ConvosCore
import Foundation
import Testing

/// Covers the pure planning logic that decides which of this device's own
/// previous installations are safe to revoke after a reinstall (the
/// keychain identity survives app deletion, the installation keys don't).
@Suite("Stale Installation Reconciler")
struct StaleInstallationReconcilerTests {
    @Test("First run seeds the marker without revoking anything")
    func firstRunSeedsMarker() {
        let plan = StaleInstallationReconciler.plan(
            marker: nil,
            inboxId: "inbox-1",
            installationId: "install-a"
        )

        #expect(plan.candidateStaleIds.isEmpty)
        #expect(plan.marker == InstallationMarker(
            inboxId: "inbox-1",
            installationId: "install-a",
            staleInstallationIds: []
        ))
    }

    @Test("Reinstall marks the previous installation stale")
    func reinstallMarksPreviousInstallationStale() {
        let marker = InstallationMarker(
            inboxId: "inbox-1",
            installationId: "install-a",
            staleInstallationIds: []
        )

        let plan = StaleInstallationReconciler.plan(
            marker: marker,
            inboxId: "inbox-1",
            installationId: "install-b"
        )

        #expect(plan.candidateStaleIds == ["install-a"])
        #expect(plan.marker.staleInstallationIds == ["install-a"])
        #expect(plan.marker.installationId == "install-b")
    }

    @Test("Unrevoked stales accumulate across reinstalls and dedupe")
    func stalesAccumulateAcrossReinstalls() {
        // Two reinstalls happened while offline: install-a's revoke never
        // succeeded, then install-b was orphaned too.
        let marker = InstallationMarker(
            inboxId: "inbox-1",
            installationId: "install-b",
            staleInstallationIds: ["install-a", "install-a"]
        )

        let plan = StaleInstallationReconciler.plan(
            marker: marker,
            inboxId: "inbox-1",
            installationId: "install-c"
        )

        #expect(plan.candidateStaleIds == ["install-a", "install-b"])
    }

    @Test("Same installation keeps retrying carried stales")
    func sameInstallationRetriesCarriedStales() {
        let marker = InstallationMarker(
            inboxId: "inbox-1",
            installationId: "install-b",
            staleInstallationIds: ["install-a"]
        )

        let plan = StaleInstallationReconciler.plan(
            marker: marker,
            inboxId: "inbox-1",
            installationId: "install-b"
        )

        #expect(plan.candidateStaleIds == ["install-a"])
        #expect(plan.marker == marker)
    }

    @Test("Inbox change resets the marker without revoking")
    func inboxChangeResetsMarker() {
        // Pairing adoption or delete-all replaced the identity wholesale;
        // the old inbox's installations are abandoned with it and the
        // devices list never shows them - nothing to revoke.
        let marker = InstallationMarker(
            inboxId: "old-inbox",
            installationId: "install-a",
            staleInstallationIds: ["install-z"]
        )

        let plan = StaleInstallationReconciler.plan(
            marker: marker,
            inboxId: "new-inbox",
            installationId: "install-b"
        )

        #expect(plan.candidateStaleIds.isEmpty)
        #expect(plan.marker == InstallationMarker(
            inboxId: "new-inbox",
            installationId: "install-b",
            staleInstallationIds: []
        ))
    }

    @Test("Current installation is never a revocation candidate")
    func currentInstallationNeverRevoked() {
        // A marker corrupted into listing the live installation as stale
        // must not produce a self-revoke.
        let marker = InstallationMarker(
            inboxId: "inbox-1",
            installationId: "install-b",
            staleInstallationIds: ["install-b", "install-a"]
        )

        let plan = StaleInstallationReconciler.plan(
            marker: marker,
            inboxId: "inbox-1",
            installationId: "install-b"
        )

        #expect(plan.candidateStaleIds == ["install-a"])
    }
}
