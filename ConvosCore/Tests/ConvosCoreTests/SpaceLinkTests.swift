@testable import ConvosCore
import Foundation
import Testing

/// The matcher behind "a link to this conversation's Space opens in the Home,
/// not in Safari". Most of this is about what may claim a Space.
@Suite("Space Link Matching")
struct SpaceLinkTests {
    private let space: URL = URL(string: "https://abcdefghijklmnop.spaces.convos.fun")!

    private func url(_ string: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: string)!
    }

    // MARK: - Matching

    @Test("The Space root and its pages match")
    func matchesSpaceAndPages() {
        #expect(SpaceLink.matches(space, space: space))
        #expect(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun/"), space: space))
        #expect(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun/goals"), space: space))
        #expect(SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun/a/b?c=d#e"), space: space))
    }

    @Test("Host comparison ignores case")
    func hostComparisonIgnoresCase() {
        #expect(SpaceLink.matches(url("HTTPS://ABCDEFGHIJKLMNOP.Spaces.Convos.fun/goals"), space: space))
    }

    @Test("Another Space does not match")
    func rejectsAnotherSpace() {
        #expect(!SpaceLink.matches(url("https://zzzzzzzzzzzzzzzz.spaces.convos.fun/goals"), space: space))
    }

    /// The whole host has to match, not a prefix of it: a lookalike that only
    /// begins with the Space's host is somebody else's server.
    @Test("A host that merely starts with the Space does not match")
    func rejectsHostPrefixLookalike() {
        #expect(!SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun.evil.com/goals"), space: space))
        #expect(!SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun.evil.com"), space: space))
    }

    /// A userinfo prefix is the classic way to make a foreign host read like
    /// the real one; `URLComponents` puts it in `user`, and `host` stays evil.
    @Test("A userinfo lookalike does not match")
    func rejectsUserinfoLookalike() {
        #expect(!SpaceLink.matches(url("https://abcdefghijklmnop.spaces.convos.fun@evil.com/goals"), space: space))
    }

    @Test("Plain http never matches")
    func rejectsPlainHTTP() {
        #expect(!SpaceLink.matches(url("http://abcdefghijklmnop.spaces.convos.fun/goals"), space: space))
    }

    @Test("Other schemes never match")
    func rejectsOtherSchemes() {
        #expect(!SpaceLink.matches(url("convos://abcdefghijklmnop.spaces.convos.fun/goals"), space: space))
        #expect(!SpaceLink.matches(url("mailto:someone@convos.org"), space: space))
    }

    @Test("Unrelated sites do not match")
    func rejectsUnrelatedSite() {
        #expect(!SpaceLink.matches(url("https://convos.fun/goals"), space: space))
        #expect(!SpaceLink.matches(url("https://example.com"), space: space))
    }

    /// 443 is what https means, so spelling it out addresses the same origin.
    @Test("An explicit default https port is the same origin as none")
    func explicitDefaultPortMatches() {
        #expect(
            SpaceLink.matches(
                url("https://abcdefghijklmnop.spaces.convos.fun:443/goals"),
                space: space
            )
        )
        #expect(
            SpaceLink.matches(
                url("https://abcdefghijklmnop.spaces.convos.fun/goals"),
                space: url("https://abcdefghijklmnop.spaces.convos.fun:443")
            )
        )
        #expect(
            SpaceLink.isRoot(
                url("https://abcdefghijklmnop.spaces.convos.fun:443/"),
                space: space
            )
        )
    }

    @Test("A non-default port is still part of the origin")
    func portIsPartOfOrigin() {
        let local: URL = url("https://localhost:8787")
        #expect(SpaceLink.matches(url("https://localhost:8787/goals"), space: local))
        #expect(!SpaceLink.matches(url("https://localhost:9999/goals"), space: local))
    }

    // MARK: - Root

    @Test("The root is the root with or without a trailing slash")
    func rootWithAndWithoutTrailingSlash() {
        #expect(SpaceLink.isRoot(space, space: space))
        #expect(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.fun/"), space: space))
    }

    /// A fragment scrolls the same page, so it is still the Home.
    @Test("A fragment alone is still the root")
    func fragmentOnlyIsStillRoot() {
        #expect(SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.fun/#section"), space: space))
    }

    /// A query is not: the site can read one, so it is a page request.
    @Test("A query on the root is not the root")
    func queryOnRootIsNotRoot() {
        #expect(!SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.fun/?tab=notes"), space: space))
    }

    @Test("A page is not the root, and a foreign URL never is")
    func pageAndForeignAreNotRoot() {
        #expect(!SpaceLink.isRoot(url("https://abcdefghijklmnop.spaces.convos.fun/goals"), space: space))
        #expect(!SpaceLink.isRoot(url("https://example.com/"), space: space))
    }

    // MARK: - Same page

    @Test("The same page is the same page")
    func samePageIsSamePage() {
        let page: URL = url("https://abcdefghijklmnop.spaces.convos.fun/goals")
        #expect(SpaceLink.isSamePage(page, as: page))
        #expect(SpaceLink.isSamePage(url("https://abcdefghijklmnop.spaces.convos.fun/goals/"), as: page))
        #expect(SpaceLink.isSamePage(space, as: url("https://abcdefghijklmnop.spaces.convos.fun/")))
    }

    /// An anchor scrolls the open page rather than opening another one.
    @Test("A fragment does not make it a different page")
    func fragmentIsSamePage() {
        #expect(
            SpaceLink.isSamePage(
                url("https://abcdefghijklmnop.spaces.convos.fun/goals#today"),
                as: url("https://abcdefghijklmnop.spaces.convos.fun/goals")
            )
        )
    }

    /// A query is readable by the page, so it is a different page.
    @Test("A different query is a different page")
    func queryMakesADifferentPage() {
        #expect(
            !SpaceLink.isSamePage(
                url("https://abcdefghijklmnop.spaces.convos.fun/goals?filter=done"),
                as: url("https://abcdefghijklmnop.spaces.convos.fun/goals")
            )
        )
    }

    // MARK: - Same location

    /// An anchor is a place on the page, and nothing can scroll a page that is
    /// already open, so a link to one is somewhere to go.
    @Test("A differing fragment is a different location")
    func fragmentIsADifferentLocation() {
        let page: URL = url("https://abcdefghijklmnop.spaces.convos.fun/goals")
        #expect(!SpaceLink.isSameLocation(url("\(page.absoluteString)#today"), as: page))
        #expect(!SpaceLink.isSameLocation(page, as: url("\(page.absoluteString)#today")))
    }

    @Test("The same location includes the same anchor")
    func sameLocationIncludesAnchor() {
        let page: URL = url("https://abcdefghijklmnop.spaces.convos.fun/goals")
        #expect(SpaceLink.isSameLocation(page, as: page))
        #expect(
            SpaceLink.isSameLocation(
                url("\(page.absoluteString)/#today"),
                as: url("\(page.absoluteString)#today")
            )
        )
    }

    @Test("A different page is a different location whatever the anchor")
    func differentPageIsADifferentLocation() {
        #expect(
            !SpaceLink.isSameLocation(
                url("https://abcdefghijklmnop.spaces.convos.fun/notes#today"),
                as: url("https://abcdefghijklmnop.spaces.convos.fun/goals#today")
            )
        )
    }

    @Test("Different paths and different hosts are different pages")
    func differentPathsAndHosts() {
        #expect(
            !SpaceLink.isSamePage(
                url("https://abcdefghijklmnop.spaces.convos.fun/goals"),
                as: url("https://abcdefghijklmnop.spaces.convos.fun/notes")
            )
        )
        #expect(
            !SpaceLink.isSamePage(
                url("https://abcdefghijklmnop.spaces.convos.fun/goals"),
                as: url("https://zzzzzzzzzzzzzzzz.spaces.convos.fun/goals")
            )
        )
    }
}
