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

    /// The sign-in calls run on their own cookie-disabled session. When that
    /// session was built as a file-static it could not see the environment, so
    /// `/auth/nonce` and `/auth/token` arrived at a preview backend with no
    /// token and were refused - which presents as a broken sign-in rather than
    /// a missing header.
    @Test("stamps the sign-in session too, without losing its cookie policy")
    func stampsSIWESession() throws {
        let session = PreviewTokenSession.makeSIWESession(for: environment(previewToken: "t0ken"))
        let headers = try #require(session.configuration.httpAdditionalHeaders)
        #expect(headers[PreviewTokenSession.header] as? String == "t0ken")
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.httpShouldSetCookies == false)
    }

    @Test("environments carry the token through from the build's secrets")
    func environmentExposesToken() {
        #expect(environment(previewToken: "abc").previewToken == "abc")
        #expect(AppEnvironment.tests.previewToken.isEmpty)
    }
}
