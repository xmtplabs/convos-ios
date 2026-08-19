import XCTest
@testable import Convos

/// The matcher behind "a link to this conversation's Space opens in the Home,
/// not in Safari". Everything here is about what may claim a Space.
final class SpaceLinkTests: XCTestCase {
    private let space: URL = URL(string: "https://abcdefghijklmnop.spaces.convos.org")!

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    // MARK: - Matching

    func testMatchesSpaceRoot() {
        XCTAssertTrue(SpaceLink.matches(space, space: space))
        XCTAssertTrue(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org/"), space: space))
    }

    func testMatchesPageInSpace() {
        XCTAssertTrue(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org/recipes"), space: space))
        XCTAssertTrue(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org/a/b?c=d#e"), space: space))
    }

    func testHostComparisonIgnoresCase() {
        XCTAssertTrue(SpaceLink.matches(url("HTTPS://ABCDEFGHIJKLMNOP.Spaces.Convos.org/recipes"), space: space))
    }

    func testRejectsAnotherSpace() {
        XCTAssertFalse(SpaceLink.matches(url("https://zzzzzzzzzzzzzzzz.spaces.convos.org/recipes"), space: space))
    }

    /// The whole host has to match, not a prefix of it: a lookalike that only
    /// begins with the Space's host is somebody else's server.
    func testRejectsHostThatMerelyStartsWithTheSpace() {
        XCTAssertFalse(
            SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org.evil.com/recipes"), space: space)
        )
        XCTAssertFalse(
            SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org.evil.com"), space: space)
        )
    }

    /// A userinfo prefix is the classic way to make a foreign host read like
    /// the real one; `URLComponents` puts it in `user`, and `host` stays evil.
    func testRejectsUserinfoLookalike() {
        XCTAssertFalse(
            SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.org@evil.com/recipes"), space: space)
        )
    }

    func testRejectsPlainHTTP() {
        XCTAssertFalse(SpaceLink.matches(url("http://abcdefghijklmnop.spaces.convos.org/recipes"), space: space))
    }

    func testRejectsOtherSchemes() {
        XCTAssertFalse(SpaceLink.matches(url("convos://abcdefghijklmnop.spaces.convos.org/recipes"), space: space))
        XCTAssertFalse(SpaceLink.matches(url("mailto:someone@convos.org"), space: space))
    }

    func testRejectsUnrelatedSite() {
        XCTAssertFalse(SpaceLink.matches(url("https://convos.org/recipes"), space: space))
        XCTAssertFalse(SpaceLink.matches(url("https://example.com"), space: space))
    }

    func testPortIsPartOfTheOrigin() {
        let local: URL = url("https://localhost:8787")
        XCTAssertTrue(SpaceLink.matches(url("https://localhost:8787/recipes"), space: local))
        XCTAssertFalse(SpaceLink.matches(url("https://localhost:9999/recipes"), space: local))
    }

    // MARK: - Root

    func testRootWithAndWithoutTrailingSlash() {
        XCTAssertTrue(SpaceLink.isRoot(space, space: space))
        XCTAssertTrue(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.org/"), space: space))
    }

    /// A fragment scrolls the same page, so it is still the Home.
    func testFragmentOnlyIsStillRoot() {
        XCTAssertTrue(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.org/#section"), space: space))
    }

    /// A query is not: the site can read one, so it is a page request.
    func testQueryOnRootIsNotRoot() {
        XCTAssertFalse(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.org/?tab=notes"), space: space))
    }

    func testPageIsNotRoot() {
        XCTAssertFalse(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.org/recipes"), space: space))
    }

    func testForeignURLIsNeverRoot() {
        XCTAssertFalse(SpaceLink.isRoot(url("https://example.com/"), space: space))
    }
}
