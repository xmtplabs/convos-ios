import Foundation

/// Lightweight persistence for which voice memo transcripts are expanded.
/// Uses `UserDefaults` since the dataset is tiny and purely device-local.
///
/// State is keyed by conversation id, so opening another conversation does not
/// pull in unrelated entries.
struct VoiceMemoTranscriptExpansionStore {
    private let defaults: UserDefaults
    private let key: String

    init(conversationId: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "VoiceMemoTranscriptExpansionStore.\(conversationId)"
    }

    func loadExpandedMessageIds() -> Set<String> {
        guard let stored = defaults.array(forKey: key) as? [String] else { return [] }
        return Set(stored)
    }

    func save(_ expanded: Set<String>) {
        if expanded.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(expanded).sorted(), forKey: key)
        }
    }
}
