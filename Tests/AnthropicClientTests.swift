import XCTest

/// Offline coverage of the request shape and every response branch.
///
/// This suite exists because the brief's original approach -- a `draft_ticket` tool with
/// `tool_choice` forced to it -- returns HTTP 400 on current models. These assertions
/// pin down the replacement and, just as importantly, assert the *absence* of the keys
/// that cause that 400, so the mistake can't quietly come back.
final class AnthropicClientTests: XCTestCase {
    // MARK: - Fixtures

    private func imagePayload() -> ImagePayload {
        ImagePayload(base64: "QUJD", mediaType: "image/png", pixelSize: CGSize(width: 1568, height: 900))
    }

    private func context() -> CaptureContext {
        var c = CaptureContext.unknown(at: Date(timeIntervalSince1970: 1_792_185_475))
        c.url = "https://staging.example.com/sites/42/editor"
        c.pageTitle = "Editor — My Site"
        c.env = "tiger"
        c.browserName = "Google Chrome"
        c.screenResolution = "3024×1964 @2x"
        return c
    }

    private func body(
        note: String = "canvas didn't update",
        productContext: String? = nil,
        areas: [String] = [],
        imageCount: Int = 1
    ) -> [String: Any] {
        AnthropicClient.requestBody(
            model: "claude-sonnet-5-5",
            images: (0..<imageCount).map { _ in imagePayload() },
            note: note,
            context: context(),
            productContext: productContext,
            areas: areas
        )
    }

    /// Round-trips through JSONSerialization, so the test sees what the server would.
    private func serializedBody(
        note: String = "x",
        productContext: String? = nil,
        areas: [String] = []
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(
            withJSONObject: body(note: note, productContext: productContext, areas: areas)
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func schemaProperties(areas: [String] = []) throws -> [String: Any] {
        try XCTUnwrap(AnthropicClient.ticketSchema(areas: areas)["properties"] as? [String: Any])
    }

    // MARK: - Request: the keys that must NOT be there

    func testRequestOmitsForcedToolUse() throws {
        let body = try serializedBody()
        XCTAssertNil(body["tools"], "tools would reintroduce the tool-call round trip")
        XCTAssertNil(body["tool_choice"], "forced tool_choice is a 400 on current models")
    }

    func testRequestOmitsThinkingEntirely() throws {
        // `thinking: {type: "disabled"}` is also a 400 on this model; omitting the key
        // runs adaptive thinking, and depth is controlled by effort instead.
        XCTAssertNil(try serializedBody()["thinking"])
    }

    func testSchemaUsesNoUnsupportedConstraints() throws {
        let data = try JSONSerialization.data(
            withJSONObject: AnthropicClient.ticketSchema(areas: ["checkout", "search", "account", "other"])
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Structured-output schemas reject these; the title limit is enforced client-side.
        for unsupported in ["maxLength", "minLength", "minItems", "maxItems", "minimum", "maximum", "pattern"] {
            XCTAssertFalse(json.contains(unsupported), "schema must not use \(unsupported)")
        }
    }

    // MARK: - Request: the shape that must be there

    func testRequestIsSerializableAtAll() throws {
        // A stray non-JSON value would throw here rather than at runtime in the app.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body()))
    }

    func testStructuredOutputFormatIsDeclared() throws {
        let body = try serializedBody()
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])

        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")
    }

    func testRefusalFallbackIsRequested() throws {
        XCTAssertEqual(try serializedBody()["fallbacks"] as? String, "default")
    }

    func testModelAndTokenCeilingArePassedThrough() throws {
        let body = try serializedBody()
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
    }

    func testSchemaRequiresEveryFieldAndForbidsExtras() throws {
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONSerialization.data(
                    withJSONObject: AnthropicClient.ticketSchema(areas: ["checkout", "search", "account", "other"])
                )
            ) as? [String: Any]
        )

        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = Set(try XCTUnwrap(schema["required"] as? [String]))
        XCTAssertEqual(required, [
            "title", "summary", "steps_to_reproduce",
            "expected", "actual", "area", "severity", "labels",
        ])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), required, "every property must be required")
    }

    /// Severity is a fixed vocabulary, so its schema enum and its Swift enum must not
    /// drift apart -- a valid response would otherwise decode to a fallback value.
    func testSeveritySchemaEnumMatchesTheSwiftEnum() throws {
        let severity = try XCTUnwrap(schemaProperties()["severity"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(severity["enum"] as? [String]),
            DraftedTicket.Severity.allCases.map(\.rawValue)
        )
    }

    // MARK: - Schema: the configured area list

    func testConfiguredAreasBecomeTheSchemaEnumInOrder() throws {
        let areas = ["checkout", "search", "admin"]
        let area = try XCTUnwrap(schemaProperties(areas: areas)["area"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(area["enum"] as? [String]), areas, "order is the user's")
        XCTAssertEqual(area["type"] as? String, "string")
    }

    /// An empty `enum` would admit no value and fail every response, so the constraint
    /// comes off entirely rather than going out empty.
    func testEmptyAreaListLeavesTheConstraintOutRatherThanEmittingAnEmptyEnum() throws {
        let area = try XCTUnwrap(schemaProperties(areas: [])["area"] as? [String: Any])

        XCTAssertNil(area["enum"], "an empty enum would reject every response")
        XCTAssertEqual(area["type"] as? String, "string")
        // Still required and still described, so the model answers with something.
        let required = try XCTUnwrap(AnthropicClient.ticketSchema()["required"] as? [String])
        XCTAssertTrue(required.contains("area"))
        XCTAssertFalse(
            try XCTUnwrap(area["description"] as? String).isEmpty,
            "with no list to pick from, the description is all the guidance there is"
        )
    }

    func testSchemaNamesNoParticularProduct() throws {
        let data = try JSONSerialization.data(
            withJSONObject: AnthropicClient.ticketSchema(areas: ["checkout"])
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
        XCTAssertFalse(json.contains("ledger"), "the schema is product-neutral")
    }

    func testConfiguredAreasReachTheRequestBody() throws {
        let body = try serializedBody(areas: ["checkout", "search"])
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let area = try XCTUnwrap(properties["area"] as? [String: Any])

        XCTAssertEqual(area["enum"] as? [String], ["checkout", "search"])
    }

    func testImageIsSentAsBase64BeforeTheText() throws {
        let body = try serializedBody()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")

        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image", "image goes first")
        XCTAssertEqual(content.last?["type"] as? String, "text")

        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "QUJD")
    }

    // MARK: - Prompts

    /// The rules are the quality of the output, so they must survive composition
    /// whether or not anything is configured.
    func testSystemPromptForbidsInventedTechnicalDetailWithOrWithoutProductContext() {
        for prompt in [
            AnthropicClient.systemPrompt(productContext: nil),
            AnthropicClient.systemPrompt(productContext: "We sell shoes online."),
        ].map({ $0.lowercased() }) {
            XCTAssertTrue(prompt.contains("never invent"))
            XCTAssertTrue(prompt.contains("console error"))
            XCTAssertTrue(prompt.contains("80 characters"))
            XCTAssertTrue(prompt.contains("assumed"))
            XCTAssertTrue(prompt.contains("quote it exactly"))
        }
    }

    func testConfiguredProductContextLeadsThePromptAndTheRulesFollowVerbatim() {
        let context = "You write bug tickets for Ledger, an accounting app."
        let prompt = AnthropicClient.systemPrompt(productContext: context)

        XCTAssertEqual(prompt, "\(context)\n\n\(AnthropicClient.draftingRules)")
        XCTAssertTrue(prompt.hasPrefix(context), "the product goes first")
        XCTAssertTrue(prompt.hasSuffix(AnthropicClient.draftingRules))
    }

    /// Nothing configured must still draft: the rules alone, with no product named.
    func testUnconfiguredProductContextLeavesTheRulesAlone() {
        for empty in [nil, "", "   \n  "] as [String?] {
            let prompt = AnthropicClient.systemPrompt(productContext: empty)
            XCTAssertEqual(prompt, AnthropicClient.draftingRules)
            XCTAssertFalse(prompt.hasPrefix("\n"), "no blank lead-in where the product would be")
        }
    }

    /// The shared rules must never pick up a product name. `ledger` is the product the
    /// other tests configure, so finding it here would mean a product context leaked in.
    func testDraftingRulesNameNoParticularProduct() {
        let rules = AnthropicClient.draftingRules.lowercased()
        XCTAssertFalse(rules.contains("ledger"))
        XCTAssertFalse(rules.contains("example.com"))
        XCTAssertFalse(rules.contains("woocommerce"))
    }

    /// A fresh board describes no product, so it drafts on the rules alone. This is the
    /// guard against a product description being committed as a default again.
    func testDefaultBoardDraftsOnTheRulesAlone() {
        XCTAssertTrue(Board().productContext.isEmpty)
        XCTAssertTrue(Board().areas.isEmpty)
        XCTAssertEqual(
            AnthropicClient.systemPrompt(productContext: Board().productContext),
            AnthropicClient.draftingRules
        )
    }

    func testProductContextReachesTheRequestBody() throws {
        let body = try serializedBody(productContext: "We sell shoes online.")
        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.hasPrefix("We sell shoes online."))
        XCTAssertTrue(system.contains("Never invent"), "the rules ride along with it")
    }

    func testUserPromptCarriesNoteAndContext() {
        let prompt = AnthropicClient.userPrompt(note: "canvas didn't update", context: context())
        XCTAssertTrue(prompt.contains("canvas didn't update"))
        XCTAssertTrue(prompt.contains("https://staging.example.com/sites/42/editor"))
        XCTAssertTrue(prompt.contains("tiger"))
        XCTAssertTrue(prompt.contains("Google Chrome"))
        XCTAssertTrue(prompt.contains("Editor — My Site"))
    }

    /// The hotkey path lets a capture be reported with no note at all, so the prompt
    /// has to say so rather than leaving a blank the model might fill with invention.
    func testUserPromptSaysWhenThereIsNoNote() {
        let prompt = AnthropicClient.userPrompt(note: "   ", context: context())
        XCTAssertTrue(prompt.contains("none given"))
    }

    func testUserPromptToleratesMissingContext() {
        let prompt = AnthropicClient.userPrompt(note: "broken", context: .unknown())
        XCTAssertTrue(prompt.contains("unknown"), "a missing URL should be stated, not blank")
        XCTAssertFalse(prompt.contains("Environment:"))
    }

    // MARK: - Response decoding

    private func response(
        text: String,
        stopReason: String = "end_turn",
        stopDetails: String = "null"
    ) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5",
         "content":[{"type":"text","text":"\(escaped)"}],
         "stop_reason":"\(stopReason)","stop_details":\(stopDetails),
         "usage":{"input_tokens":10,"output_tokens":20}}
        """.utf8)
    }

    private let validTicketJSON = """
    {"title":"Chat confirms section added but canvas doesn't update",
     "summary":"The assistant reports the section was added, but the canvas is unchanged.",
     "steps_to_reproduce":["Open the editor","Ask chat to add a pricing section","Watch the canvas (assumed)"],
     "expected":"The new section appears on the canvas.",
     "actual":"The canvas is unchanged; chat says it succeeded.",
     "area":"editor","severity":"major","labels":["canvas","chat"]}
    """

    func testDecodesAValidTicket() throws {
        let ticket = try AnthropicClient.decodeTicket(from: response(text: validTicketJSON))

        XCTAssertEqual(ticket.title, "Chat confirms section added but canvas doesn't update")
        XCTAssertEqual(ticket.area, "editor")
        XCTAssertEqual(ticket.severity, .major)
        XCTAssertEqual(ticket.stepsToReproduce.count, 3)
        XCTAssertEqual(ticket.labels, ["canvas", "chat"])
        XCTAssertTrue(ticket.stepsToReproduce[2].hasSuffix("(assumed)"))
    }

    /// The schema can't enforce the 80-character ceiling, so the client must.
    func testOverlongTitleIsClampedOnDecode() throws {
        let json = validTicketJSON.replacingOccurrences(
            of: "Chat confirms section added but canvas doesn't update",
            with: String(repeating: "z", count: 300)
        )
        let ticket = try AnthropicClient.decodeTicket(from: response(text: json))
        XCTAssertEqual(ticket.title.count, DraftedTicket.titleLimit)
    }

    func testRefusalIsReportedAsRefusalNotAsBadJSON() {
        let data = response(
            text: "I can't help with that.",
            stopReason: "refusal",
            stopDetails: #"{"type":"refusal","category":"cyber","explanation":"declined"}"#
        )
        XCTAssertThrowsError(try AnthropicClient.decodeTicket(from: data)) { error in
            guard case AnthropicClient.Failure.refused(let category, _) = error else {
                return XCTFail("expected .refused, got \(error)")
            }
            XCTAssertEqual(category, "cyber")
        }
    }

    func testTruncatedResponseIsReportedAsTruncated() {
        // Cut mid-JSON, exactly as a max_tokens stop would leave it.
        let data = response(text: #"{"title":"half a tick"#, stopReason: "max_tokens")
        XCTAssertThrowsError(try AnthropicClient.decodeTicket(from: data)) { error in
            guard case AnthropicClient.Failure.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testEmptyContentIsReportedClearly() {
        let data = Data("""
        {"content":[],"stop_reason":"end_turn","stop_details":null}
        """.utf8)
        XCTAssertThrowsError(try AnthropicClient.decodeTicket(from: data)) { error in
            guard case AnthropicClient.Failure.noContent = error else {
                return XCTFail("expected .noContent, got \(error)")
            }
        }
    }

    /// An area outside the configured list is the model's word for where the bug is, so
    /// it's kept. Severity is a fixed vocabulary, so an unknown value falls back.
    func testUnknownAreaIsKeptAndUnknownSeverityFallsBack() throws {
        let json = validTicketJSON
            .replacingOccurrences(of: #""area":"editor""#, with: #""area":"teleportation""#)
            .replacingOccurrences(of: #""severity":"major""#, with: #""severity":"catastrophic""#)

        let ticket = try AnthropicClient.decodeTicket(from: response(text: json))
        XCTAssertEqual(ticket.area, "teleportation", "an unlisted area must not cost the draft")
        XCTAssertEqual(ticket.severity, .major)
        XCTAssertEqual(ticket.title, "Chat confirms section added but canvas doesn't update")
    }

    /// With no configured list the schema doesn't constrain the area, so the response
    /// may carry anything -- or nothing at all.
    func testMissingAreaDecodesToAnEmptyAreaRatherThanFailing() throws {
        let json = validTicketJSON.replacingOccurrences(of: #""area":"editor","#, with: "")

        let ticket = try AnthropicClient.decodeTicket(from: response(text: json))
        XCTAssertEqual(ticket.area, "")
        XCTAssertEqual(ticket.severity, .major)
        XCTAssertFalse(ticket.title.isEmpty, "the rest of the draft survives")
    }

    func testMissingFieldIsReportedAsUndecodable() {
        let json = #"{"title":"only a title"}"#
        XCTAssertThrowsError(try AnthropicClient.decodeTicket(from: response(text: json))) { error in
            guard case AnthropicClient.Failure.undecodable = error else {
                return XCTFail("expected .undecodable, got \(error)")
            }
        }
    }

    // MARK: - HTTP failures

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testSuccessStatusPasses() {
        XCTAssertNoThrow(try AnthropicClient.checkHTTP(response: httpResponse(200), data: Data()))
    }

    func testBadKeyIsReportedAsUnauthorized() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertThrowsError(try AnthropicClient.checkHTTP(response: httpResponse(401), data: body)) { error in
            guard case AnthropicClient.Failure.unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    func testRateLimitIsReportedAsRateLimited() {
        XCTAssertThrowsError(try AnthropicClient.checkHTTP(response: httpResponse(429), data: Data())) { error in
            guard case AnthropicClient.Failure.rateLimited = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
        }
    }

    /// A 400 carries the reason the request was rejected, and that reason is the most
    /// useful thing we could possibly show -- so it must survive into the message.
    func testBadRequestSurfacesTheAPIMessage() {
        let body = Data("""
        {"type":"error","error":{"type":"invalid_request_error",
         "message":"tool_choice: type \\"tool\\" and \\"any\\" are not supported for this model."}}
        """.utf8)
        XCTAssertThrowsError(try AnthropicClient.checkHTTP(response: httpResponse(400), data: body)) { error in
            guard case AnthropicClient.Failure.api(let status, let type, let message) = error else {
                return XCTFail("expected .api, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(type, "invalid_request_error")
            XCTAssertTrue(message.contains("not supported for this model"))
        }
    }

    func testUnparseableErrorBodyStillProducesAMessage() {
        XCTAssertThrowsError(
            try AnthropicClient.checkHTTP(response: httpResponse(503), data: Data("upstream down".utf8))
        ) { error in
            guard case AnthropicClient.Failure.api(_, _, let message) = error else {
                return XCTFail("expected .api, got \(error)")
            }
            XCTAssertEqual(message, "upstream down")
        }
    }

    // MARK: - Several captures

    /// A single image is sent bare, exactly as it always was: the common request must
    /// not change shape just because the code can now send more.
    func testOneImageIsSentWithoutALabel() throws {
        let content = try XCTUnwrap(firstMessageContent(body()))

        XCTAssertEqual(content.count, 2, "one image block and the prompt")
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[1]["type"] as? String, "text")
    }

    /// Several images are labelled, which is Anthropic's guidance: without labels the
    /// model can't refer to a particular screenshot in the steps it writes.
    func testSeveralImagesAreLabelledInOrder() throws {
        let content = try XCTUnwrap(firstMessageContent(body(imageCount: 3)))

        // label, image, label, image, label, image, prompt
        XCTAssertEqual(content.count, 7)
        XCTAssertEqual(content[0]["text"] as? String, "Screenshot 1 of 3:")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[2]["text"] as? String, "Screenshot 2 of 3:")
        XCTAssertEqual(content[3]["type"] as? String, "image")
        XCTAssertEqual(content[4]["text"] as? String, "Screenshot 3 of 3:")
        XCTAssertEqual(content[5]["type"] as? String, "image")
        XCTAssertEqual(content[6]["type"] as? String, "text")
    }

    /// And the prompt has to say they're one bug, or the model writes one ticket per
    /// screenshot.
    func testThePromptExplainsTheSetOnlyWhenThereIsOne() {
        let single = AnthropicClient.userPrompt(note: "x", context: context(), captureCount: 1)
        XCTAssertFalse(single.contains("same bug"))
        XCTAssertTrue(single.contains("Draft the ticket from the screenshot"))

        let several = AnthropicClient.userPrompt(note: "x", context: context(), captureCount: 3)
        XCTAssertTrue(several.contains("same bug"))
        XCTAssertTrue(several.contains("Draft the ticket from the 3 screenshots"))
        XCTAssertTrue(several.contains("(assumed)"), "the honesty rule still applies")
    }

    /// Pulls the user message's content blocks out of a built request body.
    private func firstMessageContent(_ body: [String: Any]) -> [[String: Any]]? {
        guard let messages = body["messages"] as? [[String: Any]],
              let first = messages.first
        else { return nil }
        return first["content"] as? [[String: Any]]
    }
}
