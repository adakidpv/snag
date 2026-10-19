import XCTest

/// ADF is the format Jira Cloud's REST v3 requires for a description, and a malformed
/// document is rejected with a 400 that mentions nothing useful. These tests pin the
/// node shapes down, including the empty-text-node trap.
final class ADFBuilderTests: XCTestCase {
    private func body(
        summary: String = "The canvas is stale after chat confirms the change.",
        steps: [String] = ["Open the editor", "Ask chat for a pricing section", "Watch the canvas (assumed)"],
        expected: String = "The section appears.",
        actual: String = "Nothing changes.",
        attachment: TicketBody.Attachment = .automatic
    ) -> TicketBody {
        TicketBody(
            summary: summary,
            steps: steps,
            expected: expected,
            actual: actual,
            environment: .init(
                url: "https://staging.example.com/sites/42",
                environmentTag: "tiger",
                browser: "Google Chrome",
                osVersion: "macOS 26.6.2",
                screenResolution: "3024×1964 @2x",
                capturedAt: Date(timeIntervalSince1970: 1_792_185_475)
            ),
            attachment: attachment
        )
    }

    /// Round-trips through JSONSerialization so the test sees what Jira would.
    private func document(_ body: TicketBody) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ADFBuilder.document(for: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func content(_ document: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(document["content"] as? [[String: Any]])
    }

    // MARK: - Document

    func testDocumentIsSerializableJSON() {
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ADFBuilder.document(for: body())))
    }

    func testDocumentHasTheRequiredRootFields() throws {
        let doc = try document(body())
        XCTAssertEqual(doc["type"] as? String, "doc")
        XCTAssertEqual(doc["version"] as? Int, 1)
        XCTAssertNotNil(doc["content"])
    }

    func testSectionsAppearInOrder(){
        let headings = headingTexts(ADFBuilder.document(for: body()))
        XCTAssertEqual(headings, ["Summary", "Steps to reproduce", "Expected", "Actual", "Environment"])
    }

    private func headingTexts(_ document: [String: Any]) -> [String] {
        guard let content = document["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { node in
            guard node["type"] as? String == "heading",
                  let inner = node["content"] as? [[String: Any]],
                  let text = inner.first?["text"] as? String
            else { return nil }
            return text
        }
    }

    func testHeadingsAreLevelThree() throws {
        for node in try content(try document(body())) where node["type"] as? String == "heading" {
            let attrs = try XCTUnwrap(node["attrs"] as? [String: Any])
            XCTAssertEqual(attrs["level"] as? Int, 3)
        }
    }

    // MARK: - Steps

    func testStepsBecomeAnOrderedListOfListItems() throws {
        let nodes = try content(try document(body()))
        let list = try XCTUnwrap(nodes.first { $0["type"] as? String == "orderedList" })
        let items = try XCTUnwrap(list["content"] as? [[String: Any]])

        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertEqual(item["type"] as? String, "listItem")
            // A listItem's child must be a block, not bare text.
            let inner = try XCTUnwrap(item["content"] as? [[String: Any]])
            XCTAssertEqual(inner.first?["type"] as? String, "paragraph")
        }
    }

    func testStepTextSurvivesIntact() throws {
        let nodes = try content(try document(body()))
        let list = try XCTUnwrap(nodes.first { $0["type"] as? String == "orderedList" })
        let items = try XCTUnwrap(list["content"] as? [[String: Any]])
        let texts = items.compactMap { item -> String? in
            guard let paragraph = (item["content"] as? [[String: Any]])?.first,
                  let text = (paragraph["content"] as? [[String: Any]])?.first?["text"] as? String
            else { return nil }
            return text
        }
        XCTAssertEqual(texts, ["Open the editor", "Ask chat for a pricing section", "Watch the canvas (assumed)"])
    }

    // MARK: - Empty content

    /// The trap worth a test: ADF allows an empty paragraph but **not** a text node
    /// whose text is "". Emitting one gets the whole document rejected.
    func testNoTextNodeIsEverEmpty() throws {
        let sparse = body(summary: "", steps: [], expected: "   ", actual: "")
        let json = try XCTUnwrap(
            String(data: try JSONSerialization.data(withJSONObject: ADFBuilder.document(for: sparse)), encoding: .utf8)
        )
        XCTAssertFalse(json.contains(#""text":"""#), "an empty text node would be rejected by Jira")

        try assertNoEmptyTextNodes(in: ADFBuilder.document(for: sparse))
        try assertNoEmptyTextNodes(in: ADFBuilder.document(for: body()))
    }

    private func assertNoEmptyTextNodes(in node: Any) throws {
        if let dictionary = node as? [String: Any] {
            if dictionary["type"] as? String == "text" {
                let text = dictionary["text"] as? String
                XCTAssertNotNil(text)
                XCTAssertFalse(text?.isEmpty ?? true, "found an empty text node")
            }
            for value in dictionary.values { try assertNoEmptyTextNodes(in: value) }
        } else if let array = node as? [Any] {
            for value in array { try assertNoEmptyTextNodes(in: value) }
        }
    }

    func testEmptySectionsAreOmittedRatherThanLeftAsBareHeadings() {
        let headings = headingTexts(
            ADFBuilder.document(for: body(summary: "", steps: [], expected: "", actual: ""))
        )
        // Environment is always present; the rest drop out with their content.
        XCTAssertEqual(headings, ["Environment"])
    }

    func testParagraphWithBlankTextHasNoContentKey() {
        let paragraph = ADFBuilder.paragraph("   ")
        XCTAssertEqual(paragraph["type"] as? String, "paragraph")
        XCTAssertNil(paragraph["content"])
    }

    // MARK: - Environment and footer

    func testEnvironmentRowsAreABulletList() throws {
        let nodes = try content(try document(body()))
        let list = try XCTUnwrap(nodes.first { $0["type"] as? String == "bulletList" })
        let items = try XCTUnwrap(list["content"] as? [[String: Any]])
        let texts = items.compactMap { item -> String? in
            guard let paragraph = (item["content"] as? [[String: Any]])?.first,
                  let text = (paragraph["content"] as? [[String: Any]])?.first?["text"] as? String
            else { return nil }
            return text
        }

        XCTAssertTrue(texts.contains { $0.hasPrefix("URL: https://staging.example.com") })
        XCTAssertTrue(texts.contains("Environment: tiger"))
        XCTAssertTrue(texts.contains("Browser: Google Chrome"))
        XCTAssertTrue(texts.contains { $0.hasPrefix("macOS: 26.6.2") })
    }

    func testUnknownEnvironmentFieldsAreSkipped() {
        var sparse = body()
        sparse.environment = .init(
            url: nil, environmentTag: nil, browser: nil,
            osVersion: "macOS 26.6.2", screenResolution: nil,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let labels = sparse.environment.rows.map(\.label)
        XCTAssertEqual(labels, ["macOS", "Captured"])
    }

    /// An engineer who reads "screenshot attached" and finds none wastes time, so the
    /// footer has to tell the truth about which path filed the ticket.
    func testFooterStatesWhetherTheScreenshotCameAlong() throws {
        let automatic = try XCTUnwrap(
            lastParagraphText(ADFBuilder.document(for: body(attachment: .automatic)))
        )
        XCTAssertEqual(automatic, "Captured with Snag — screenshot attached.")

        let manual = try XCTUnwrap(
            lastParagraphText(ADFBuilder.document(for: body(attachment: .manual)))
        )
        XCTAssertEqual(manual, "Captured with Snag — screenshot attached manually.")
    }

    private func lastParagraphText(_ document: [String: Any]) -> String? {
        guard let content = document["content"] as? [[String: Any]],
              let paragraph = content.last,
              paragraph["type"] as? String == "paragraph"
        else { return nil }
        return (paragraph["content"] as? [[String: Any]])?.first?["text"] as? String
    }
}
