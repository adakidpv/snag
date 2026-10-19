import Foundation

extension String {
    /// Trimmed, or `nil` when there's nothing left. Used wherever a blank field should
    /// mean "unset" rather than "empty string" -- a whitespace-only note, a cleared
    /// model name, a page title the browser reports as "".
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
