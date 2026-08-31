import Foundation

/// Remembers the last document each Space served, across view rebuilds.
///
/// The Context tab's root is hosted in a `UINavigationController` whose
/// `rootView` is reassigned on every update pass, and pushing or popping a
/// browsed page is one of those passes. The root is an `AnyView`, so SwiftUI
/// loses its identity each time and `@State` starts over — which, without this,
/// means coming back from a page refetches the document and flashes the loading
/// state at a reader who never left.
///
/// Holding the outcome outside the view makes a rebuild free. The cache is
/// per-process and deliberately unbounded: it holds one small tree per Space a
/// reader has actually opened.
@MainActor
final class SpaceDocumentStore {
    static let shared: SpaceDocumentStore = SpaceDocumentStore()

    /// What a Space last answered. A failure is not recorded — it is usually
    /// transient, and retrying costs one request while showing a stale error
    /// costs the reader the page.
    enum Outcome: Equatable {
        case loaded(SpaceDocument)
        /// This deployment does not serve documents; the web page does.
        case unsupported(String)
    }

    private var outcomes: [URL: Outcome] = [:]

    func outcome(for spaceURL: URL) -> Outcome? {
        outcomes[spaceURL]
    }

    func record(_ outcome: Outcome, for spaceURL: URL) {
        outcomes[spaceURL] = outcome
    }
}
