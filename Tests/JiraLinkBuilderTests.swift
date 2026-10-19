import XCTest

/// The brief calls for unit tests on encoding, truncation and multiple labels
/// specifically. These are them.
final class JiraLinkBuilderTests: XCTestCase {
    private func request(
        summary: String = "Canvas doesn't update",
        description: String = "h3. Summary\nThe canvas is stale.",
        labels: [String] = []
    ) -> JiraLinkBuilder.Request {
        .init(
            site: "example",
            projectID: "10001",
            issueTypeID: "10004",
            summary: summary,
            description: description,
            labels: labels
        )
    }

    private func queryItems(_ url: URL) -> [(String, String)] {
        // Parsed by hand: URLComponents would decode and collapse the repeated
        // `labels` parameter this builder relies on.
        guard let query = url.query else { return [] }
        return query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (name, value)
        }
    }

    // MARK: - Shape

    func testBuildsTheCreateIssueEndpoint() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request()))
        XCTAssertTrue(
            url.absoluteString.hasPrefix(
                "https://example.atlassian.net/secure/CreateIssueDetails!init.jspa?"
            ),
            url.absoluteString
        )
    }

    func testCarriesProjectAndIssueType() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request()))
        let items = Dictionary(uniqueKeysWithValues: queryItems(url).filter { $0.0 != "labels" })
        XCTAssertEqual(items["pid"], "10001")
        XCTAssertEqual(items["issuetype"], "10004")
    }

    func testNoSiteMeansNoURL() {
        var r = request()
        r.site = "  "
        XCTAssertNil(JiraLinkBuilder.url(for: r))
    }

    // MARK: - Encoding

    func testSpacesAndPunctuationArePercentEncoded() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(summary: "Canvas doesn't update")))
        let summary = queryItems(url).first { $0.0 == "summary" }?.1
        XCTAssertEqual(summary, "Canvas%20doesn%27t%20update")
    }

    /// The characters that would otherwise break out of the query value. An unescaped
    /// `&` would silently truncate the summary and inject a bogus parameter.
    func testQueryDelimitersAreEncodedNotPassedThrough() throws {
        let url = try XCTUnwrap(
            JiraLinkBuilder.url(for: request(summary: "a&b=c+d?e#f"))
        )
        let summary = try XCTUnwrap(queryItems(url).first { $0.0 == "summary" }?.1)
        XCTAssertEqual(summary, "a%26b%3Dc%2Bd%3Fe%23f")
        for forbidden in ["&b", "=c", "+d", "?e", "#f"] {
            XCTAssertFalse(summary.contains(forbidden))
        }
    }

    func testNewlinesInTheDescriptionAreEncoded() throws {
        let url = try XCTUnwrap(
            JiraLinkBuilder.url(for: request(description: "line one\nline two"))
        )
        let description = try XCTUnwrap(queryItems(url).first { $0.0 == "description" }?.1)
        XCTAssertTrue(description.contains("%0A"))
        XCTAssertFalse(description.contains("\n"))
    }

    func testNonASCIISurvivesEncoding() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(summary: "Canvas — stale ✅")))
        let summary = try XCTUnwrap(queryItems(url).first { $0.0 == "summary" }?.1)
        XCTAssertTrue(summary.contains("%E2%80%94"), "em dash")
        XCTAssertTrue(summary.contains("%E2%9C%85"), "emoji")
    }

    // MARK: - Labels

    /// Jira takes multiple labels as a repeated parameter, not a joined string.
    func testEachLabelGetsItsOwnParameter() throws {
        let url = try XCTUnwrap(
            JiraLinkBuilder.url(for: request(labels: ["web", "canvas", "from-snag"]))
        )
        let labels = queryItems(url).filter { $0.0 == "labels" }.map(\.1)
        XCTAssertEqual(labels, ["web", "canvas", "from-snag"])
    }

    func testNoLabelsMeansNoLabelParameter() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(labels: [])))
        XCTAssertTrue(queryItems(url).filter { $0.0 == "labels" }.isEmpty)
    }

    /// Jira rejects labels with whitespace, so they're hyphenated rather than sent
    /// as-is and failing the create.
    func testLabelsWithSpacesAreHyphenated() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(labels: ["no repro", "P1 bug"])))
        let labels = queryItems(url).filter { $0.0 == "labels" }.map(\.1)
        XCTAssertEqual(labels, ["no-repro", "p1-bug"])
    }

    func testDuplicateLabelsAreCollapsed() {
        XCTAssertEqual(
            TicketBody.sanitizeLabels(["web", "WEB", " web ", "canvas"]),
            ["web", "canvas"]
        )
    }

    // MARK: - Truncation

    func testShortDescriptionIsNotTruncated() throws {
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(description: "short")))
        XCTAssertFalse(url.absoluteString.contains("truncated"))
    }

    func testLongDescriptionIsTruncatedAndMarked() throws {
        let long = String(repeating: "The canvas did not update. ", count: 1000)
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(description: long)))

        XCTAssertLessThanOrEqual(url.absoluteString.count, JiraLinkBuilder.maxURLLength)
        let decoded = try XCTUnwrap(
            queryItems(url).first { $0.0 == "description" }?.1.removingPercentEncoding
        )
        XCTAssertTrue(decoded.hasSuffix(JiraLinkBuilder.truncationMarker), decoded.suffix(60).description)
    }

    /// Encoded length is what counts against the limit: a description made entirely of
    /// characters that triple in size when escaped would blow the budget if raw
    /// characters were counted instead.
    func testTruncationAccountsForEncodedLengthNotRawLength() throws {
        let newlines = String(repeating: "\n", count: 5000)
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(description: newlines)))
        XCTAssertLessThanOrEqual(url.absoluteString.count, JiraLinkBuilder.maxURLLength)
    }

    func testTruncationHandlesMultiByteCharactersWithoutSplittingThem() throws {
        let emoji = String(repeating: "✅", count: 4000)
        let url = try XCTUnwrap(JiraLinkBuilder.url(for: request(description: emoji)))

        XCTAssertLessThanOrEqual(url.absoluteString.count, JiraLinkBuilder.maxURLLength)
        // A split multi-byte sequence would fail to decode at all.
        let decoded = queryItems(url).first { $0.0 == "description" }?.1.removingPercentEncoding
        XCTAssertNotNil(decoded, "percent-decoding failed, so a character was cut in half")
    }

    /// Even with an absurd summary eating the whole budget, the URL must stay valid
    /// rather than the builder producing nonsense or crashing.
    func testExtremeSummaryStillYieldsAValidURL() throws {
        let url = JiraLinkBuilder.url(
            for: request(summary: String(repeating: "x", count: 8000), description: "body")
        )
        XCTAssertNotNil(url, "should still build a URL even when over budget")
    }

    func testTruncateDirectlyRespectsTheLimit() {
        let text = String(repeating: "abcdefghij", count: 500)
        let truncated = JiraLinkBuilder.truncate(text, toEncodedLength: 200)
        XCTAssertLessThanOrEqual(JiraLinkBuilder.encode(truncated).count, 200)
        XCTAssertTrue(truncated.hasSuffix(JiraLinkBuilder.truncationMarker))
    }

    func testTruncateWithNoRoomReturnsJustTheMarker() {
        XCTAssertEqual(
            JiraLinkBuilder.truncate(String(repeating: "x", count: 100), toEncodedLength: 5),
            JiraLinkBuilder.truncationMarker
        )
    }
}
