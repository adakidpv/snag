import Foundation

/// Builds a prefilled Jira create-issue URL.
///
/// This is the fallback path, for tenants where an API token can't be issued. It uses
/// the legacy `CreateIssueDetails!init.jspa` endpoint, which on Jira Cloud prefills the
/// summary and labels reliably but may not carry the description into the current issue
/// editor -- which is why the Report panel also offers "Copy ticket text", and why the
/// REST path is the default.
enum JiraLinkBuilder {
    /// Browsers and servers both get unhappy with very long URLs well before any hard
    /// limit, so the description is truncated to keep the whole URL under this.
    static let maxURLLength = 6000
    static let truncationMarker = "[truncated — see attachment]"

    struct Request {
        var site: String
        var projectID: String
        var issueTypeID: String
        var summary: String
        var description: String
        var labels: [String]
    }

    /// Returns nil only when the site is blank -- there's nothing to build a URL from.
    static func url(for request: Request) -> URL? {
        guard let site = request.site.nilIfEmpty else { return nil }
        let base = "https://\(site).atlassian.net/secure/CreateIssueDetails!init.jspa"

        // Everything except the description is fixed-length, so build those first and
        // spend whatever budget is left on the description.
        var fixed: [(String, String)] = [
            ("pid", request.projectID),
            ("issuetype", request.issueTypeID),
            ("summary", request.summary),
        ]
        // Multiple labels are expressed as a repeated parameter, not a joined string.
        for label in TicketBody.sanitizeLabels(request.labels) {
            fixed.append(("labels", label))
        }

        let fixedQuery = fixed.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        let prefix = "\(base)?\(fixedQuery)&description="

        let budget = maxURLLength - prefix.count
        let description = truncate(request.description, toEncodedLength: max(budget, 0))

        return URL(string: prefix + encode(description))
    }

    /// Percent-encodes for a query *value*. `URLComponents` would leave `&`, `+` and
    /// `=` alone, which breaks the query it's embedded in, so the allowed set is
    /// restricted to unreserved characters.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Trims `text` so that its *encoded* length fits `limit`, appending the marker.
    ///
    /// Encoded length is what matters: a newline or an em dash costs three or nine
    /// characters once escaped, so counting raw characters would overshoot badly on a
    /// description full of punctuation.
    static func truncate(_ text: String, toEncodedLength limit: Int) -> String {
        guard encode(text).count > limit else { return text }

        let markerCost = encode("\n\n" + truncationMarker).count
        let budget = limit - markerCost
        guard budget > 0 else { return truncationMarker }

        // Walk back from the end until the encoded form fits. Done on characters, not
        // bytes, so a multi-byte character is never split in half.
        var kept = Array(text)
        while !kept.isEmpty, encode(String(kept)).count > budget {
            // Drop a proportional chunk first so a long description doesn't take
            // thousands of iterations, then fine-tune one character at a time.
            let overshoot = encode(String(kept)).count - budget
            let drop = max(1, min(kept.count, overshoot / 3))
            kept.removeLast(drop)
        }

        // Prefer a clean break at whitespace when one is close by.
        if let lastSpace = kept.lastIndex(where: { $0.isWhitespace }),
           kept.distance(from: lastSpace, to: kept.endIndex) < 40 {
            kept = Array(kept[kept.startIndex..<lastSpace])
        }

        let trimmed = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? truncationMarker : trimmed + "\n\n" + truncationMarker
    }
}
