import Foundation

/// Parsing and formatting for Jira issue keys like `ABC-412`.
///
/// The brief has the user pasting a key back into a snag by hand, which means the input
/// is whatever was on the clipboard: the bare key, a lowercased key, stray whitespace,
/// or the whole browse URL copied from the address bar. All of those should end up as a
/// working link rather than a dead one -- and anything that *isn't* a key should be
/// rejected outright rather than turned into a plausible-looking broken link.
enum JiraKey {
    /// A project key (uppercase alphanumerics, underscores allowed), a dash, and the
    /// issue number. Anchored, so a token must match in full.
    private static let pattern = "^[A-Z][A-Z0-9_]*-[0-9]+$"

    static func normalize(_ raw: String?) -> String? {
        guard let raw = raw?.nilIfEmpty else { return nil }

        // A pasted browse URL carries the key as its last path component.
        var candidate = raw
        if let components = URLComponents(string: raw), components.host != nil {
            candidate = components.path
        }
        if let lastPathComponent = candidate.split(separator: "/").last {
            candidate = String(lastPathComponent)
        }

        // Accept a key sitting in a short phrase ("ABC-412 is fixed") by testing each
        // whitespace-separated token, while still requiring each token to match whole --
        // so "NOTAKEY-1X" yields nothing instead of "NOTAKEY-1".
        return candidate
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    static func browseURL(site: String, key: String) -> URL? {
        guard let site = site.nilIfEmpty else { return nil }
        return URL(string: "https://\(site).atlassian.net/browse/\(key)")
    }
}
