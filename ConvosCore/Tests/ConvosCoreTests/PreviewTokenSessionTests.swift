@testable import ConvosCore
import Foundation
import Testing

struct PreviewTokenSessionTests {
    private func environment(previewToken: String) -> AppEnvironment {
        .dev(config: ConvosConfiguration(
            apiBaseURL: "https://pr-1.dev.convos.xyz/api",
            appGroupIdentifier: "group.org.convos.tests",
            relyingPartyIdentifier: "convos.org",
            siweConfiguration: SIWEConfiguration(
                domain: "dev.convos.org",
                uri: "https://dev.convos.org",
                chainId: 1
            ),
            previewToken: previewToken
        ))
    }

    @Test("stamps the preview token on every request through the session")
    func stampsToken() throws {
        let configuration = PreviewTokenSession.configuration(for: environment(previewToken: "t0ken"))
        let headers = try #require(configuration.httpAdditionalHeaders)
        #expect(headers[PreviewTokenSession.header] as? String == "t0ken")
    }

    /// A normal build has no token, and sending an empty one would be worse
    /// than sending none: the gate compares in constant time and would reject
    /// it, turning "not a preview build" into a 503 on every call.
    @Test("adds no header when the build has no token")
    func omitsHeaderWithoutToken() {
        let configuration = PreviewTokenSession.configuration(for: environment(previewToken: ""))
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    @Test("environments carry the token through from the build's secrets")
    func environmentExposesToken() {
        #expect(environment(previewToken: "abc").previewToken == "abc")
        #expect(AppEnvironment.tests.previewToken.isEmpty)
    }
}
