import XCTest

/// `TicketBody` is the single source both renderers read, so these tests cover the
/// content decisions once -- and check that the wiki-markup rendering the brief
/// specifies (`h3.` headings, `#` steps) comes out right.
final class TicketBodyTests: XCTestCase {
    private func draft() -> DraftedTicket {
        DraftedTicket(
            title: "Chat confirms section added but canvas doesn't update",
            summary: "The assistant reports success; the canvas is unchanged.",
            stepsToReproduce: ["Open the editor", "Ask chat for a pricing section", "Watch the canvas (assumed)"],
            expected: "The new section appears.",
            actual: "The canvas is unchanged.",
            area: "editor",
            severity: .major,
            labels: ["canvas", "chat"]
        )
    }

    private func context() -> CaptureContext {
        var c = CaptureContext.unknown(at: Date(timeIntervalSince1970: 1_792_185_475))
        c.url = "https://staging.example.com/sites/42"
        c.env = "tiger"
        c.browserName = "Google Chrome"
        c.screenResolution = "3024×1964 @2x"
        return c
    }

    // MARK: - Construction

    func testBuildsFromADraftAndContext() {
        let body = TicketBody.make(from: draft(), context: context(), attachment: .automatic)

        XCTAssertEqual(body.summary, "The assistant reports success; the canvas is unchanged.")
        XCTAssertEqual(body.steps.count, 3)
        XCTAssertEqual(body.environment.environmentTag, "tiger")
        XCTAssertEqual(body.environment.url, "https://staging.example.com/sites/42")
    }

    func testBlankStepsAreDropped() {
        var d = draft()
        d.stepsToReproduce = ["Open the editor", "   ", "", "Watch the canvas"]
        let body = TicketBody.make(from: d, context: context(), attachment: .automatic)
        XCTAssertEqual(body.steps, ["Open the editor", "Watch the canvas"])
    }

    func testMissingContextBecomesNilRatherThanEmptyStrings() {
        var c = CaptureContext.unknown()
        c.url = "  "
        c.env = ""
        let body = TicketBody.make(from: draft(), context: c, attachment: .automatic)

        XCTAssertNil(body.environment.url)
        XCTAssertNil(body.environment.environmentTag)
        XCTAssertNil(body.environment.browser)
    }

    // MARK: - Wiki markup

    func testWikiMarkupUsesTheBriefsHeadingAndListSyntax() {
        let markup = TicketBody.make(from: draft(), context: context(), attachment: .manual).wikiMarkup()

        XCTAssertTrue(markup.contains("h3. Summary"))
        XCTAssertTrue(markup.contains("h3. Steps to reproduce"))
        XCTAssertTrue(markup.contains("h3. Expected"))
        XCTAssertTrue(markup.contains("h3. Actual"))
        XCTAssertTrue(markup.contains("h3. Environment"))
        XCTAssertTrue(markup.contains("# Open the editor"))
        XCTAssertTrue(markup.contains("# Watch the canvas (assumed)"))
    }

    func testWikiMarkupSectionsAppearInOrder() {
        let markup = TicketBody.make(from: draft(), context: context(), attachment: .manual).wikiMarkup()
        let order = ["h3. Summary", "h3. Steps to reproduce", "h3. Expected", "h3. Actual", "h3. Environment"]

        var searchFrom = markup.startIndex
        for heading in order {
            guard let found = markup.range(of: heading, range: searchFrom..<markup.endIndex) else {
                return XCTFail("\(heading) missing or out of order")
            }
            searchFrom = found.upperBound
        }
    }

    func testWikiMarkupIncludesTheEnvironmentBlock() {
        let markup = TicketBody.make(from: draft(), context: context(), attachment: .manual).wikiMarkup()
        XCTAssertTrue(markup.contains("https://staging.example.com/sites/42"))
        XCTAssertTrue(markup.contains("tiger"))
        XCTAssertTrue(markup.contains("Google Chrome"))
    }

    func testWikiMarkupOmitsEmptySectionsRatherThanLeavingBareHeadings() {
        var d = draft()
        d.summary = ""
        d.stepsToReproduce = []
        d.expected = "  "
        let markup = TicketBody.make(from: d, context: context(), attachment: .manual).wikiMarkup()

        XCTAssertFalse(markup.contains("h3. Summary"))
        XCTAssertFalse(markup.contains("h3. Steps to reproduce"))
        XCTAssertFalse(markup.contains("h3. Expected"))
        XCTAssertTrue(markup.contains("h3. Actual"), "a section with content should survive")
        XCTAssertTrue(markup.contains("h3. Environment"), "environment is always present")
    }

    func testFooterMatchesTheFilingPath() {
        let automatic = TicketBody.make(from: draft(), context: context(), attachment: .automatic)
        XCTAssertTrue(automatic.wikiMarkup().hasSuffix("Captured with Snag — screenshot attached."))

        let manual = TicketBody.make(from: draft(), context: context(), attachment: .manual)
        XCTAssertTrue(manual.wikiMarkup().hasSuffix("Captured with Snag — screenshot attached manually."))
    }

    /// Both renderers read the same structure, so the same facts must reach both.
    func testBothRenderersCarryTheSameFacts() throws {
        let body = TicketBody.make(from: draft(), context: context(), attachment: .automatic)
        let markup = body.wikiMarkup()
        let adf = try XCTUnwrap(
            String(
                data: try JSONSerialization.data(withJSONObject: ADFBuilder.document(for: body)),
                encoding: .utf8
            )
        )

        for fact in [
            "The assistant reports success",
            "Ask chat for a pricing section",
            "The new section appears",
            "staging.example.com",
            "Google Chrome",
        ] {
            XCTAssertTrue(markup.contains(fact), "wiki markup is missing: \(fact)")
            XCTAssertTrue(adf.contains(fact), "ADF is missing: \(fact)")
        }
    }

    // MARK: - Labels

    func testLabelSanitisation() {
        XCTAssertEqual(TicketBody.sanitizeLabels(["Canvas", "no repro"]), ["canvas", "no-repro"])
        XCTAssertEqual(TicketBody.sanitizeLabels(["  ", ""]), [])
        XCTAssertEqual(TicketBody.sanitizeLabels(["a\tb", "c\nd"]), ["a-b", "c-d"])
    }
}
