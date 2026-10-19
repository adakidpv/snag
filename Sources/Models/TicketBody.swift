import Foundation

/// The ticket description, as structure rather than as a string.
///
/// One source for both outputs: `ADFBuilder` renders it for the REST API (which needs
/// Atlassian Document Format JSON), and `wikiMarkup()` renders it for the prefilled-URL
/// fallback. Keeping the structure in the middle means the two can't drift, and means
/// the content is testable without touching either renderer.
struct TicketBody: Equatable {
    struct Environment: Equatable {
        var url: String?
        var environmentTag: String?
        var browser: String?
        var osVersion: String
        var screenResolution: String?
        var capturedAt: Date

        /// Label/value pairs, in the order engineers scan them, skipping anything unknown.
        var rows: [(label: String, value: String)] {
            var rows: [(String, String)] = []
            if let url { rows.append(("URL", url)) }
            if let environmentTag { rows.append(("Environment", environmentTag)) }
            if let browser { rows.append(("Browser", browser)) }
            rows.append(("macOS", osVersion.replacingOccurrences(of: "macOS ", with: "")))
            if let screenResolution { rows.append(("Screen", screenResolution)) }
            rows.append(("Captured", Self.timestampFormatter.string(from: capturedAt)))
            return rows
        }

        private static let timestampFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.timeZone = TimeZone.current
            return f
        }()

        static func == (lhs: Environment, rhs: Environment) -> Bool {
            lhs.url == rhs.url && lhs.environmentTag == rhs.environmentTag
                && lhs.browser == rhs.browser && lhs.osVersion == rhs.osVersion
                && lhs.screenResolution == rhs.screenResolution
                && lhs.capturedAt == rhs.capturedAt
        }
    }

    /// Whether the captures ride along automatically or the user has to attach them,
    /// and how many there are. It changes what the footer line promises, which matters
    /// -- an engineer reading "screenshot attached" and finding none, or finding one of
    /// three, wastes their time.
    enum Attachment: Equatable {
        case automatic(count: Int)
        case manual(count: Int)

        static let automatic = Attachment.automatic(count: 1)
        static let manual = Attachment.manual(count: 1)

        private var subject: String {
            switch self {
            case .automatic(let count), .manual(let count):
                return count > 1 ? "\(count) screenshots attached" : "screenshot attached"
            }
        }

        var footer: String {
            switch self {
            case .automatic:
                return "Captured with Snag — \(subject)."
            case .manual:
                return "Captured with Snag — \(subject) manually."
            }
        }
    }

    var summary: String
    var steps: [String]
    var expected: String
    var actual: String
    var environment: Environment
    var attachment: Attachment

    static func make(
        from draft: DraftedTicket,
        context: CaptureContext,
        attachment: Attachment
    ) -> TicketBody {
        TicketBody(
            summary: draft.summary,
            steps: draft.stepsToReproduce.compactMap { $0.nilIfEmpty },
            expected: draft.expected,
            actual: draft.actual,
            environment: Environment(
                url: context.url?.nilIfEmpty,
                environmentTag: context.env?.nilIfEmpty,
                browser: context.browserName?.nilIfEmpty,
                osVersion: context.osVersion,
                screenResolution: context.screenResolution?.nilIfEmpty,
                capturedAt: context.capturedAt
            ),
            attachment: attachment
        )
    }

    /// Jira wiki markup, for the prefilled-URL fallback: `h3.` headings and `#` for
    /// numbered steps, as the brief specifies. Empty sections are omitted rather than
    /// left as a bare heading.
    func wikiMarkup() -> String {
        var blocks: [String] = []

        if let summary = summary.nilIfEmpty {
            blocks.append("h3. Summary\n\(summary)")
        }
        if !steps.isEmpty {
            let list = steps.map { "# \($0)" }.joined(separator: "\n")
            blocks.append("h3. Steps to reproduce\n\(list)")
        }
        if let expected = expected.nilIfEmpty {
            blocks.append("h3. Expected\n\(expected)")
        }
        if let actual = actual.nilIfEmpty {
            blocks.append("h3. Actual\n\(actual)")
        }

        let rows = environment.rows.map { "* *\($0.label):* \($0.value)" }.joined(separator: "\n")
        blocks.append("h3. Environment\n\(rows)")
        blocks.append(attachment.footer)

        return blocks.joined(separator: "\n\n")
    }

    /// Jira rejects labels containing whitespace, so a drafted label like "no repro"
    /// becomes "no-repro" instead of failing the whole create call.
    static func sanitizeLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap { label -> String? in
            let cleaned = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "\t", with: "-")
                .replacingOccurrences(of: "\n", with: "-")
            guard let cleaned = cleaned.nilIfEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }
}
