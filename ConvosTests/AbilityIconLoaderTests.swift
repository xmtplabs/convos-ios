@testable import Convos
import ConvosCore
import UIKit
import XCTest

/// The icons flickered because every fresh `AbilityIconView` had to reach the
/// network layer asynchronously before it could draw. What removes the
/// flicker is the synchronous memory hit, so that is what these pin - along
/// with the version scoping that keeps a bumped icon from serving the
/// previous one's bytes.
final class AbilityIconLoaderTests: XCTestCase {
    private var cachedKeys: [String] = []

    override func tearDown() {
        for key in cachedKeys {
            ImageCache.shared.removeImage(for: key)
        }
        cachedKeys = []
        super.tearDown()
    }

    func testCachedIconIsNilBeforeAnythingIsCached() throws {
        let url = try makeIconURL(slug: uniqueSlug("googlecalendar"), version: 1)

        XCTAssertNil(AbilityIconLoader.cachedIcon(for: url))
    }

    func testCachedIconReturnsTheCachedImageSynchronously() throws {
        let url = try makeIconURL(slug: uniqueSlug("gmail"), version: 1)
        cache(makeIcon(), for: url)

        XCTAssertNotNil(AbilityIconLoader.cachedIcon(for: url))
    }

    func testIconResolvesFromTheCacheWithoutFetching() async throws {
        let url = try makeIconURL(slug: uniqueSlug("spotify"), version: 1)
        cache(makeIcon(), for: url)

        let resolved = await AbilityIconLoader.icon(for: url)

        XCTAssertNotNil(resolved)
    }

    /// The icon URL carries the version, so a bumped icon must miss rather
    /// than resolve to the previous version's cached bytes.
    func testABumpedIconVersionDoesNotResolveToThePreviousVersion() throws {
        // The two URLs differ only in the version segment.
        let slug = uniqueSlug("coinbase")
        let firstVersion = try makeIconURL(slug: slug, version: 1)
        let secondVersion = try makeIconURL(slug: slug, version: 2)
        cache(makeIcon(), for: firstVersion)

        XCTAssertNotNil(AbilityIconLoader.cachedIcon(for: firstVersion))
        XCTAssertNil(AbilityIconLoader.cachedIcon(for: secondVersion))
    }

    // MARK: - Helpers

    /// Unique per test so the process-wide `ImageCache` cannot carry an entry
    /// between them.
    private func uniqueSlug(_ name: String) -> String {
        "\(name)-\(UUID().uuidString)"
    }

    /// The shape the backend serves: slug, version, `.png`.
    private func makeIconURL(slug: String, version: Int) throws -> URL {
        try XCTUnwrap(URL(string: "https://example.invalid/ability-icons/\(slug)-v\(version).png"))
    }

    private func makeIcon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func cache(_ image: UIImage, for url: URL) {
        let key = AbilityIconLoader.cacheKey(for: url)
        cachedKeys.append(key)
        ImageCache.shared.cacheImage(image, for: key, imageFormat: .png)
    }
}
