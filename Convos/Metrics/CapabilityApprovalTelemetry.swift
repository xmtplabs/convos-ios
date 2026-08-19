import Foundation
import PostHog

/// Counter for the blocked-approval path: an agent DM whose origin could not
/// back a grant at approve time. The residual population (a roster lane whose
/// DM truly has no origin marker) should be empty by construction, so this
/// counter exists to let reality contradict that claim; a sustained rate is
/// the signal to escalate to worker-side lane invalidation.
enum CapabilityApprovalTelemetry {
    static func blockedApproval(reason: String) {
        PostHogSDK.shared.capture(
            "capability_approval_blocked",
            properties: ["reason": reason]
        )
    }
}
