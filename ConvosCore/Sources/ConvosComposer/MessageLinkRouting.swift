#if canImport(UIKit)
import Foundation
import SwiftUI

/// A host's chance to take a link tapped in a transcript itself, rather than
/// let it leave the app. Returns true when it took it.
///
/// The conversation screen uses this for links into its own Space: the agent
/// builds pages for the group there and posts them to the chat, and those
/// pages are what the Home is already showing behind the sheet. Handing one to
/// Safari would send the reader out of the app to reach something the app has.
public typealias MessageLinkRouter = @MainActor (URL) -> Bool

private struct MessageLinkRouterKey: EnvironmentKey {
    /// No host handler: every link belongs to somebody else's site.
    static let defaultValue: MessageLinkRouter = { _ in false }
}

public extension EnvironmentValues {
    /// Injected at the cell alongside `agentShareResolver`, so bubbles don't
    /// have to thread a handler down through the messages hierarchy.
    var messageLinkRouter: MessageLinkRouter {
        get { self[MessageLinkRouterKey.self] }
        set { self[MessageLinkRouterKey.self] = newValue }
    }
}

private struct ConversationSpaceURLKey: EnvironmentKey {
    /// No Space, so no link can belong to one.
    static let defaultValue: URL? = nil
}

public extension EnvironmentValues {
    /// The conversation's own Space, injected beside `messageLinkRouter` for
    /// the bubbles that render a link differently when it points home - see
    /// `SpaceLink`. Nil until the Space exists.
    var conversationSpaceURL: URL? {
        get { self[ConversationSpaceURLKey.self] }
        set { self[ConversationSpaceURLKey.self] = newValue }
    }
}

/// The one door transcript links go through: the host first, the in-app
/// browser for everything it declines.
public enum MessageLinkOpener {
    @MainActor
    public static func open(_ url: URL, router: MessageLinkRouter) {
        guard !router(url) else { return }
        InAppBrowser.open(url)
    }
}
#endif
