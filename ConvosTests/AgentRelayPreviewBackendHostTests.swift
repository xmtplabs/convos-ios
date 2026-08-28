@testable import Convos
import ConvosCore
import XCTest

final class AgentRelayPreviewBackendHostTests: XCTestCase {
    func testRecognizesOnlyPerPRPreviewBackendHosts() {
        XCTAssertTrue(ConfigManager.isPreviewBackendHost("pr-1234.dev.convos.xyz"))
        XCTAssertTrue(ConfigManager.isPreviewBackendHost("PR-1234.dev.convos.xyz"))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost("api.dev.convos.xyz"))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost("10.0.0.5"))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost("abcd1234.ngrok.app"))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost(nil))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost(""))
        XCTAssertFalse(ConfigManager.isPreviewBackendHost("not a url"))
    }
}
