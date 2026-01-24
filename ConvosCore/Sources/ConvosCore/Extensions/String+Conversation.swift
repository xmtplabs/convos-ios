import Foundation

public extension Optional where Wrapped == String {
    /// Returns the string if it's non-nil and non-empty, otherwise returns "Untitled"
    var orUntitled: String {
        guard let self, !self.isEmpty else {
            return "Untitled"
        }
        return self
    }
}

public extension String {
    /// Returns "Untitled" if the string is empty, otherwise returns the string itself
    var orUntitled: String {
        (isEmpty ? nil : self).orUntitled
    }
}

public extension Optional where Wrapped == String {
    /// Formats source message text for reaction previews.
    /// Returns quoted, truncated text or "a message" fallback.
    func formattedAsReactionSource(maxLength: Int = 30) -> String {
        guard let text = self, !text.isEmpty else {
            return "a message"
        }
        let truncated = text.count > maxLength
            ? String(text.prefix(maxLength)) + "…"
            : text
        return "'\(truncated)'"
    }
}
