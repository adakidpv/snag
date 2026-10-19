import XCTest

/// Covers the request shapes and every failure branch offline. The live round trip
/// against a real tenant is the one thing these can't prove -- that's what the
/// README's verification step is for.
final class JiraClientTests: XCTestCase {
    private func body() -> TicketBody {
        TicketBody(
            summary: "The canvas is stale.",
            steps: ["Open the editor", "Ask chat for a section"],
            expected: "It appears.",
            actual: "It doesn't.",
            environment: .init(
                url: "https://staging.example.com", environmentTag: "tiger",
                browser: "Google Chrome", osVersion: "macOS 26.6.2",
                screenResolution: nil, capturedAt: Date(timeIntervalSince1970: 0)
            ),
            attachment: .automatic
        )
    }

    private func createBody(labels: [String] = ["canvas"]) throws -> [String: Any] {
        let raw = JiraClient.createIssueBody(
            title: "Canvas doesn't update",
            body: body(),
            labels: labels,
            projectID: "10001",
            issueTypeID: "10004"
        )
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fields() throws -> [String: Any] {
        try XCTUnwrap(try createBody()["fields"] as? [String: Any])
    }

    // MARK: - Create request

    func testCreateBodyIsSerializable() {
        XCTAssertNoThrow(try createBody())
    }

    func testProjectAndIssueTypeGoByID() throws {
        let fields = try fields()
        XCTAssertEqual((fields["project"] as? [String: Any])?["id"] as? String, "10001")
        XCTAssertEqual((fields["issuetype"] as? [String: Any])?["id"] as? String, "10004")
    }

    func testSummaryIsTheTitle() throws {
        XCTAssertEqual(try fields()["summary"] as? String, "Canvas doesn't update")
    }

    /// The whole reason for `ADFBuilder`: v3 rejects a plain string here.
    func testDescriptionIsAnADFDocumentNotAString() throws {
        let fields = try fields()
        XCTAssertNil(fields["description"] as? String, "a string description is a 400 on v3")
        let description = try XCTUnwrap(fields["description"] as? [String: Any])
        XCTAssertEqual(description["type"] as? String, "doc")
        XCTAssertEqual(description["version"] as? Int, 1)
    }

    func testLabelsAreSanitisedInTheCreateBody() throws {
        let raw = JiraClient.createIssueBody(
            title: "t", body: body(), labels: ["Canvas", "no repro", "canvas"],
            projectID: "1", issueTypeID: "2"
        )
        let fields = try XCTUnwrap(raw["fields"] as? [String: Any])
        XCTAssertEqual(fields["labels"] as? [String], ["canvas", "no-repro"])
    }

    // MARK: - Configuration guards

    /// Each missing field should be named, so the user knows which one to fix rather
    /// than seeing a generic failure after a network round trip.
    func testMissingConfigurationIsReportedBeforeAnyNetworkCall() async {
        let cases: [(JiraClient, String)] = [
            (JiraClient(site: "", accountEmail: "a@b.com", apiToken: "t"), "site"),
            (JiraClient(site: "example", accountEmail: "", apiToken: "t"), "email"),
            (JiraClient(site: "example", accountEmail: "a@b.com", apiToken: ""), "token"),
        ]

        for (client, expected) in cases {
            do {
                _ = try await client.file(
                    title: "t", body: body(), labels: [],
                    projectID: "1", issueTypeID: "2", attachments: []
                )
                XCTFail("expected a configuration failure for \(expected)")
            } catch let JiraClient.Failure.missingConfiguration(what) {
                XCTAssertTrue(
                    what.lowercased().contains(expected),
                    "\"\(what)\" should name the \(expected)"
                )
            } catch {
                XCTFail("expected .missingConfiguration, got \(error)")
            }
        }
    }

    func testMissingProjectAndIssueTypeAreAlsoCaught() async {
        let client = JiraClient(site: "example", accountEmail: "a@b.com", apiToken: "t")
        do {
            _ = try await client.file(
                title: "t", body: body(), labels: [],
                projectID: "", issueTypeID: "2", attachments: []
            )
            XCTFail("expected a configuration failure")
        } catch let JiraClient.Failure.missingConfiguration(what) {
            XCTAssertTrue(what.contains("Project ID"))
        } catch {
            XCTFail("expected .missingConfiguration, got \(error)")
        }
    }

    // MARK: - Multipart attachment

    func testMultipartUsesTheFileFieldNameJiraRequires() throws {
        let data = JiraClient.multipartBody(
            boundary: "BOUNDARY",
            filename: "snag.png",
            mimeType: "image/png",
            fileData: Data("PNGDATA".utf8)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains(#"name="file""#), "Jira ignores any other field name")
        XCTAssertTrue(text.contains(#"filename="snag.png""#))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
        XCTAssertTrue(text.contains("PNGDATA"))
        XCTAssertTrue(text.hasPrefix("--BOUNDARY\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--BOUNDARY--\r\n"), "the closing boundary must be terminated")
    }

    func testMultipartPreservesBinaryDataExactly() {
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x1A, 0x0A])
        let data = JiraClient.multipartBody(
            boundary: "B", filename: "f.png", mimeType: "image/png", fileData: binary
        )
        XCTAssertTrue(
            data.range(of: binary) != nil,
            "the file bytes must survive unmodified"
        )
    }

    /// Library files are named by UUID, which is useless in a ticket.
    func testAttachmentGetsAReadableFilename() {
        let name = JiraClient.attachmentFilename(
            for: URL(fileURLWithPath: "/tmp/8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21.png")
        )
        XCTAssertTrue(name.hasPrefix("snag-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains("8C6E8A3E"))
    }

    func testMimeTypesCoverCapturesAndFallBackSafely() {
        XCTAssertEqual(JiraClient.mimeType(for: URL(fileURLWithPath: "a.png")), "image/png")
        XCTAssertEqual(JiraClient.mimeType(for: URL(fileURLWithPath: "a.JPG")), "image/jpeg")
        XCTAssertEqual(JiraClient.mimeType(for: URL(fileURLWithPath: "a.mov")), "video/quicktime")
        XCTAssertEqual(JiraClient.mimeType(for: URL(fileURLWithPath: "a.xyz")), "application/octet-stream")
    }

    // MARK: - Response handling

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.atlassian.net/rest/api/3/issue")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    func testSuccessPasses() {
        XCTAssertNoThrow(try JiraClient.checkResponse(response(201), data: Data()))
    }

    func testBadCredentialsAreReportedAsUnauthorized() {
        XCTAssertThrowsError(try JiraClient.checkResponse(response(401), data: Data())) { error in
            guard case JiraClient.Failure.unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    func testNoPermissionIsReportedAsForbidden() {
        XCTAssertThrowsError(try JiraClient.checkResponse(response(403), data: Data())) { error in
            guard case JiraClient.Failure.forbidden = error else {
                return XCTFail("expected .forbidden, got \(error)")
            }
        }
    }

    /// The most likely real-world rejection is a required custom field on the project's
    /// Bug screen. Jira names the field; that name must reach the user.
    func testFieldLevelRejectionsReachTheUser() {
        let body = Data("""
        {"errorMessages":[],"errors":{"customfield_10010":"Sprint is required",
         "summary":"Summary must be less than 255 characters"}}
        """.utf8)

        XCTAssertThrowsError(try JiraClient.checkResponse(response(400), data: body)) { error in
            guard case JiraClient.Failure.rejected(let status, let messages) = error else {
                return XCTFail("expected .rejected, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(messages.contains("customfield_10010: Sprint is required"))
            XCTAssertTrue(messages.contains { $0.contains("Summary must be less than") })
        }
    }

    func testGeneralErrorMessagesAreCarriedThrough() {
        let body = Data(#"{"errorMessages":["Issue type is not valid for this project."]}"#.utf8)
        XCTAssertThrowsError(try JiraClient.checkResponse(response(400), data: body)) { error in
            guard case JiraClient.Failure.rejected(_, let messages) = error else {
                return XCTFail("expected .rejected, got \(error)")
            }
            XCTAssertEqual(messages, ["Issue type is not valid for this project."])
        }
    }

    func testNonJSONErrorBodyStillProducesSomething() {
        XCTAssertThrowsError(
            try JiraClient.checkResponse(response(502), data: Data("Bad Gateway".utf8))
        ) { error in
            guard case JiraClient.Failure.rejected(_, let messages) = error else {
                return XCTFail("expected .rejected, got \(error)")
            }
            XCTAssertEqual(messages, ["Bad Gateway"])
        }
    }

    /// A failed attachment must read as a partial success, because the ticket exists --
    /// anything else invites the user to file the same bug twice.
    func testAttachmentFailureMessageNamesTheCreatedIssue() {
        let error = JiraClient.Failure.attachmentFailed(issueKey: "BUG-412", reason: "413 too large")
        let message = try! XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("BUG-412"))
        XCTAssertTrue(message.lowercased().contains("created"))
        XCTAssertTrue(message.contains("413 too large"))
    }
}
