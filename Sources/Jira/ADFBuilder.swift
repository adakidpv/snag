import Foundation

/// Renders a `TicketBody` as Atlassian Document Format.
///
/// **Why this exists rather than sending wiki markup.** Jira Cloud's REST v3 takes rich
/// text as ADF JSON, not a string. The usual workaround is to post to v2 instead, which
/// is documented as accepting wiki markup -- but the sources saying it still does on
/// Cloud are old and contradict each other, and that's a poor foundation for the one
/// step that decides whether filing works at all. The content here is a fixed, known
/// shape (a few headings, a numbered list, a bullet list), so emitting ADF directly is
/// about sixty lines and leaves nothing to verify at runtime.
///
/// This is not a general Markdown-to-ADF converter and shouldn't grow into one.
enum ADFBuilder {
    /// The node types this emits: doc, heading, paragraph, text, orderedList,
    /// bulletList, listItem.
    static func document(for body: TicketBody) -> [String: Any] {
        var content: [[String: Any]] = []

        if let summary = body.summary.nilIfEmpty {
            content.append(heading("Summary"))
            content.append(paragraph(summary))
        }

        if !body.steps.isEmpty {
            content.append(heading("Steps to reproduce"))
            content.append(orderedList(body.steps))
        }

        if let expected = body.expected.nilIfEmpty {
            content.append(heading("Expected"))
            content.append(paragraph(expected))
        }

        if let actual = body.actual.nilIfEmpty {
            content.append(heading("Actual"))
            content.append(paragraph(actual))
        }

        content.append(heading("Environment"))
        content.append(bulletList(body.environment.rows.map { "\($0.label): \($0.value)" }))
        content.append(paragraph(body.attachment.footer))

        return [
            "type": "doc",
            "version": 1,
            "content": content,
        ]
    }

    // MARK: - Nodes

    static func heading(_ text: String, level: Int = 3) -> [String: Any] {
        [
            "type": "heading",
            "attrs": ["level": level],
            "content": [textNode(text)],
        ]
    }

    /// A paragraph with no content is valid ADF; a *text node* whose text is empty is
    /// not, and Jira rejects the whole document for it. So blank text yields an empty
    /// paragraph rather than a paragraph containing an empty text node.
    static func paragraph(_ text: String) -> [String: Any] {
        guard let text = text.nilIfEmpty else { return ["type": "paragraph"] }
        return ["type": "paragraph", "content": [textNode(text)]]
    }

    static func orderedList(_ items: [String]) -> [String: Any] {
        ["type": "orderedList", "content": items.map(listItem)]
    }

    static func bulletList(_ items: [String]) -> [String: Any] {
        ["type": "bulletList", "content": items.map(listItem)]
    }

    private static func listItem(_ text: String) -> [String: Any] {
        ["type": "listItem", "content": [paragraph(text)]]
    }

    private static func textNode(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
}
