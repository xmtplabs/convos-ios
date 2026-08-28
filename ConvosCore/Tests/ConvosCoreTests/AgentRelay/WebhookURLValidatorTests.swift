@testable import ConvosCore
import Testing

@Suite("AgentRelay webhook URL validator")
struct AgentRelayWebhookURLValidatorTests {
    @Test("benchmarking, site-local, and mapped IPv4 ranges are classified")
    func comprehensiveRangeAdditions() {
        let validator = WebhookURLValidator(environment: makeConfiguredEnvironment(local: false))
        let cases: [(host: String, shouldBlock: Bool)] = [
            ("198.17.255.255", false),
            ("198.18.0.1", true),
            ("2620::1", false),
            ("fec0::1", true),
            ("::ffff:8.8.8.8", false),
            ("::ffff:127.0.0.1", true),
        ]

        for testCase in cases {
            let formattedHost = testCase.host.contains(":") ? "[\(testCase.host)]" : testCase.host
            do {
                _ = try validator.validate("https://\(formattedHost)/")
                if testCase.shouldBlock {
                    Issue.record("Expected \(testCase.host) to be blocked")
                }
            } catch {
                if !testCase.shouldBlock {
                    Issue.record("Expected \(testCase.host) to be accepted, got \(error)")
                }
            }
        }
    }
}
