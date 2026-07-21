import Foundation

/// A quiet artifact update: the agent re-sent an artifact to keep it current
/// without asking for the group's attention.
///
/// The intent rides the attachment's filename because an attachment message
/// carries nothing else the sender controls — no metadata bag, and
/// `contentDigest` is a digest of the encrypted payload that changes on every
/// send. The runtime stages a copy named `notes~quiet.html` and sends that;
/// this type is the client half of that agreement.
///
/// Two consequences follow from stripping the sentinel back off:
/// the update still supersedes its predecessor in Files & Links and the Things
/// view, because those dedupe on filename and the canonical name is unchanged;
/// and the transcript skips drawing another card for it.
///
/// The durable version of this is a silent control message naming the
/// superseded message id, the way `BuilderBundleManifest` already hides
/// builder briefs from the transcript on every client.
public enum QuietArtifactUpdate {
    static let sentinel: String = "~quiet"

    /// True when this filename marks a quiet update.
    public static func isQuiet(filename: String?) -> Bool {
        guard let filename else { return false }
        return (filename as NSString).deletingPathExtension.hasSuffix(sentinel)
    }

    /// The artifact's real filename, with the sentinel removed. Returns the
    /// input unchanged when there is none, so callers can apply it blindly.
    public static func canonicalFilename(_ filename: String?) -> String? {
        guard let filename, isQuiet(filename: filename) else { return filename }
        let name = filename as NSString
        let ext = name.pathExtension
        let stem = String(name.deletingPathExtension.dropLast(sentinel.count))
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
