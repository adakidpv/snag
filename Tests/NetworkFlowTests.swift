import XCTest

/// Drives the real `AnthropicClient.draftTicket` and `JiraClient.file` against stubbed
/// HTTP. This covers what the pure-shape tests can't: the headers actually sent, the
/// body that lands on the wire, and the behaviour on each kind of failure -- including
/// the offline case the brief's checklist calls out.
final class NetworkFlowTests: XCTestCase {
    private var directory: URL!
    private var screenshot: URL!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NetworkFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        screenshot = directory.appendingPathComponent("capture.png")
        try Self.writePNG(to: screenshot, width: 2400, height: 1400)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real PNG, so `ImagePayload` does real work rather than being stubbed out.
    private static func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "test", code: 1)
        }
    }

    private func context() -> CaptureContext {
        var c = CaptureContext.unknown()
        c.url = "https://staging.example.com/sites/42"
        c.env = "tiger"
        c.browserName = "Google Chrome"
        return c
    }

    private func anthropicClient() -> AnthropicClient {
        AnthropicClient(
            apiKey: "sk-ant-test",
            model: "claude-sonnet-5-5",
            session: StubURLProtocol.session()
        )
    }

    /// The ticket JSON as it arrives: a string *inside* the response JSON, so it must
    /// stay on one line with its quotes escaped.
    private let ticketJSON = #"{\"title\":\"Canvas doesn't update after chat confirms\",\"summary\":\"Chat reports success but the canvas is unchanged.\",\"steps_to_reproduce\":[\"Open the editor\",\"Ask for a section\"],\"expected\":\"It appears.\",\"actual\":\"It doesn't.\",\"area\":\"editor\",\"severity\":\"major\",\"labels\":[\"canvas\"]}"#

    private var successResponse: String {
        """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5",
         "content":[{"type":"text","text":"\(ticketJSON)"}],
         "stop_reason":"end_turn","stop_details":null}
        """
    }

    // MARK: - Image preparation

    func testScreenshotIsDownscaledToTheGuidanceLimit() throws {
        let payload = try ImagePayload.make(from: screenshot)

        XCTAssertLessThanOrEqual(max(payload.pixelSize.width, payload.pixelSize.height), ImagePayload.maxLongEdge)
        XCTAssertFalse(payload.base64.isEmpty)
        XCTAssertTrue(["image/png", "image/jpeg"].contains(payload.mediaType))
        XCTAssertNotNil(Data(base64Encoded: payload.base64), "base64 must decode")
    }

    func testUnreadableCaptureIsReportedNotCrashed() {
        let missing = directory.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try ImagePayload.make(from: missing))
    }

    // MARK: - Drafting, end to end

    func testDraftTicketSendsTheExpectedHeadersAndBody() async throws {
        StubURLProtocol.enqueue(.json(successResponse))

        let ticket = try await anthropicClient().draftTicket(
            captures: [screenshot], note: "canvas didn't update", context: context()
        )
        XCTAssertEqual(ticket.title, "Canvas doesn't update after chat confirms")
        XCTAssertEqual(ticket.area, "editor")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-beta"),
            "server-side-fallback-2026-07-01",
            "the refusal fallback needs its beta header to take effect"
        )

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(StubURLProtocol.bodies.first)) as? [String: Any]
        )
        XCTAssertNil(body["tool_choice"], "forced tool use is a 400 on this model")
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["fallbacks"] as? String, "default")

        // The screenshot really is in there, as base64.
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content.first?["source"] as? [String: Any])
        let base64 = try XCTUnwrap(source["data"] as? String)
        XCTAssertNotNil(Data(base64Encoded: base64))
    }

    /// The brief's checklist: an offline network must not crash, and must say so.
    func testOfflineIsReportedAsOffline() async {
        StubURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))

        do {
            _ = try await anthropicClient().draftTicket(
                captures: [screenshot], note: "x", context: context()
            )
            XCTFail("expected a failure")
        } catch let AnthropicClient.Failure.offline(detail) {
            XCTAssertFalse(detail.isEmpty)
        } catch {
            XCTFail("expected .offline, got \(error)")
        }
    }

    func testTimeoutIsReportedAsOffline() async {
        StubURLProtocol.enqueue(.failure(URLError(.timedOut)))
        do {
            _ = try await anthropicClient().draftTicket(
                captures: [screenshot], note: "x", context: context()
            )
            XCTFail("expected a failure")
        } catch AnthropicClient.Failure.offline {
            // expected
        } catch {
            XCTFail("expected .offline, got \(error)")
        }
    }

    /// The brief's checklist: a missing key must be caught before any request.
    func testMissingKeyFailsWithoutCallingTheAPI() async {
        let client = AnthropicClient(apiKey: "", model: "m", session: StubURLProtocol.session())
        do {
            _ = try await client.draftTicket(captures: [screenshot], note: "x", context: context())
            XCTFail("expected a failure")
        } catch AnthropicClient.Failure.missingAPIKey {
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request should have been attempted")
        } catch {
            XCTFail("expected .missingAPIKey, got \(error)")
        }
    }

    func testRejectedKeyIsReportedAsUnauthorized() async {
        StubURLProtocol.enqueue(
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid"}}"#, status: 401)
        )
        do {
            _ = try await anthropicClient().draftTicket(
                captures: [screenshot], note: "x", context: context()
            )
            XCTFail("expected a failure")
        } catch AnthropicClient.Failure.unauthorized {
            // expected
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
    }

    func testPingReturnsTheServedModel() async throws {
        StubURLProtocol.enqueue(.json(successResponse))
        let model = try await anthropicClient().ping()
        XCTAssertEqual(model, "claude-sonnet-5-5")
    }

    // MARK: - Jira filing, end to end

    private func jiraClient() -> JiraClient {
        JiraClient(
            site: "example",
            accountEmail: "qa@example.com",
            apiToken: "token123",
            session: StubURLProtocol.session()
        )
    }

    private func body() -> TicketBody {
        TicketBody(
            summary: "Canvas is stale.", steps: ["Open the editor"],
            expected: "It appears.", actual: "It doesn't.",
            environment: .init(
                url: "https://staging.example.com", environmentTag: "tiger",
                browser: "Google Chrome", osVersion: "macOS 26.6.2",
                screenResolution: nil, capturedAt: Date(timeIntervalSince1970: 0)
            ),
            attachment: .automatic
        )
    }

    func testFileCreatesTheIssueThenAttachesTheCapture() async throws {
        StubURLProtocol.enqueue(
            .json(#"{"id":"10100","key":"BUG-412","self":"https://example.atlassian.net/rest/api/3/issue/10100"}"#, status: 201),
            .json(#"[{"id":"20001","filename":"snag.png"}]"#, status: 200)
        )

        let issue = try await jiraClient().file(
            title: "Canvas doesn't update",
            body: body(),
            labels: ["canvas"],
            projectID: "10001",
            issueTypeID: "10004",
            attachments: [screenshot]
        )

        XCTAssertEqual(issue.key, "BUG-412")
        XCTAssertEqual(issue.id, "10100")

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 2, "one create, one attach")

        // Create
        XCTAssertEqual(requests[0].url?.path, "/rest/api/3/issue")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let auth = try XCTUnwrap(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("Basic "))
        let decoded = String(
            data: try XCTUnwrap(Data(base64Encoded: String(auth.dropFirst("Basic ".count)))),
            encoding: .utf8
        )
        XCTAssertEqual(decoded, "qa@example.com:token123")

        // Attach
        XCTAssertEqual(requests[1].url?.path, "/rest/api/3/issue/BUG-412/attachments")
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "X-Atlassian-Token"),
            "no-check",
            "Jira's XSRF check rejects the attachment endpoint without this"
        )
        let contentType = try XCTUnwrap(requests[1].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let attachBody = try XCTUnwrap(StubURLProtocol.bodies.last)
        let preamble = String(decoding: attachBody.prefix(300), as: UTF8.self)
        XCTAssertTrue(preamble.contains(#"name="file""#))
    }

    func testCreateSendsADFNotAString() async throws {
        StubURLProtocol.enqueue(
            .json(#"{"id":"1","key":"BUG-1"}"#, status: 201),
            .json("[]", status: 200)
        )
        _ = try await jiraClient().file(
            title: "t", body: body(), labels: [],
            projectID: "1", issueTypeID: "2", attachments: []
        )

        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(StubURLProtocol.bodies.first)) as? [String: Any]
        )
        let fields = try XCTUnwrap(sent["fields"] as? [String: Any])
        let description = try XCTUnwrap(fields["description"] as? [String: Any])
        XCTAssertEqual(description["type"] as? String, "doc")
    }

    func testNoAttachmentMeansOnlyOneRequest() async throws {
        StubURLProtocol.enqueue(.json(#"{"id":"1","key":"BUG-1"}"#, status: 201))
        _ = try await jiraClient().file(
            title: "t", body: body(), labels: [],
            projectID: "1", issueTypeID: "2", attachments: []
        )
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    /// The important partial-failure case: the issue was created, so the error must
    /// carry its key rather than reading as a total loss.
    func testAttachmentFailureStillReportsTheCreatedKey() async {
        StubURLProtocol.enqueue(
            .json(#"{"id":"10100","key":"BUG-412"}"#, status: 201),
            .json(#"{"errorMessages":["The attachment exceeds the maximum size."]}"#, status: 413)
        )

        do {
            _ = try await jiraClient().file(
                title: "t", body: body(), labels: [],
                projectID: "1", issueTypeID: "2", attachments: [screenshot]
            )
            XCTFail("expected a failure")
        } catch let JiraClient.Failure.attachmentFailed(key, reason) {
            XCTAssertEqual(key, "BUG-412")
            XCTAssertTrue(reason.contains("maximum size"))
        } catch {
            XCTFail("expected .attachmentFailed, got \(error)")
        }
    }

    func testJiraOfflineIsReportedAsOffline() async {
        StubURLProtocol.enqueue(.failure(URLError(.cannotFindHost)))
        do {
            _ = try await jiraClient().file(
                title: "t", body: body(), labels: [],
                projectID: "1", issueTypeID: "2", attachments: []
            )
            XCTFail("expected a failure")
        } catch JiraClient.Failure.offline {
            // expected
        } catch {
            XCTFail("expected .offline, got \(error)")
        }
    }

    func testSuccessWithoutAKeyInTheResponseIsReportedAsUnexpected() async {
        StubURLProtocol.enqueue(.json(#"{"id":"10100"}"#, status: 201))
        do {
            _ = try await jiraClient().file(
                title: "t", body: body(), labels: [],
                projectID: "1", issueTypeID: "2", attachments: []
            )
            XCTFail("expected a failure")
        } catch JiraClient.Failure.unexpected {
            // expected
        } catch {
            XCTFail("expected .unexpected, got \(error)")
        }
    }
}
