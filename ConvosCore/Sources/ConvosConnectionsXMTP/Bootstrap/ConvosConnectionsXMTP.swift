import Foundation
@preconcurrency import XMTPiOS

/// One-stop registration helper. Host code merges `ConvosConnectionsXMTP.codecs()` into
/// its existing `ClientOptions(codecs: [...])` when constructing the XMTP client.
///
/// Exposed as a namespaced enum rather than free functions so call sites read clearly
/// alongside existing Convos client construction code.
public enum ConvosConnectionsXMTP {
    /// The three ConvosConnections wire types.
    ///
    /// Returns fresh instances on every call because XMTPiOS's `ContentCodec` is a value
    /// type with no shared state — cheap to construct, no reason to cache.
    public static func codecs() -> [any ContentCodec] {
        [
            ConnectionPayloadCodec(),
            ConnectionInvocationCodec(),
            ConnectionInvocationResultCodec(),
        ]
    }
}
