import Foundation

/// The one place Snag talks to the Claude API.
///
/// **Why structured outputs rather than a forced tool call.** The brief specified a
/// `draft_ticket` tool definition with `tool_choice` pinned to it. That shape returns
/// HTTP 400 on current models -- forced tool use (`tool_choice` `any`/`tool`) was
/// removed on Claude Sonnet 5.5 and Claude Opus 5.5. `output_config.format` with a JSON
/// schema is the supported way to guarantee a parseable shape, and it's less machinery:
/// no tool round-trip, the JSON arrives in the first text block.
///
/// Two consequences worth knowing:
///  - Schemas can't express `maxLength`, so the 80-character title ceiling is asked for
///    in the prompt and enforced in `DraftedTicket.clampingTitle()`.
///  - `thinking` must not be sent as `disabled` (also a 400 on this model). It's
///    omitted entirely and depth is controlled with `effort`.
struct AnthropicClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    /// Enables the server-side refusal fallback below.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// Drafting a bug ticket from a screenshot is not deep reasoning, and the user is
    /// watching a spinner -- latency matters more than thoroughness here.
    private static let effort = "low"
    private static let maxTokens = 8192

    let apiKey: String
    let model: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 90

    // MARK: - Errors

    enum Failure: Error, LocalizedError {
        case missingAPIKey
        case offline(String)
        case unauthorized
        case rateLimited
        case api(status: Int, type: String?, message: String)
        case refused(category: String?, explanation: String?)
        case truncated
        case noContent
        case undecodable(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key. Add one in Settings."
            case .offline(let detail):
                return "Couldn't reach the Claude API: \(detail)"
            case .unauthorized:
                return "The Anthropic API key was rejected. Check it in Settings."
            case .rateLimited:
                return "Rate limited by the Claude API. Try again in a moment."
            case .api(let status, let type, let message):
                return "Claude API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
            case .refused(let category, let explanation):
                let reason = explanation ?? category ?? "no reason given"
                return "Claude declined to draft this ticket (\(reason))."
            case .truncated:
                return "The draft was cut off before it finished. Try again."
            case .noContent:
                return "Claude returned an empty response."
            case .undecodable(let detail):
                return "Couldn't read Claude's reply: \(detail)"
            }
        }
    }

    // MARK: - Drafting

    /// `productContext` and `areas` are the configured, product-specific half of the
    /// prompt -- `Board.productContext` and `Board.normalizedAreas` for the board being
    /// filed to. Both are optional: with neither, drafting runs on the product-neutral
    /// rules and an unconstrained area, which still yields a usable ticket.
    /// `captures` is primary first, in the order the reporter arranged them, and holds
    /// only images -- a recording is attached to the ticket but never sent here.
    func draftTicket(
        captures: [URL],
        note: String,
        context: CaptureContext,
        productContext: String? = nil,
        areas: [String] = []
    ) async throws -> DraftedTicket {
        guard apiKey.nilIfEmpty != nil else { throw Failure.missingAPIKey }
        guard !captures.isEmpty else { throw Failure.noContent }

        let images = try captures.map { try ImagePayload.make(from: $0) }
        let body = Self.requestBody(
            model: model,
            images: images,
            note: note,
            context: context,
            productContext: productContext,
            areas: areas
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.drafting.notice("""
            drafting with \(model, privacy: .public) from \
            \(images.count, privacy: .public) image(s), first \
            \(Int(images[0].pixelSize.width), privacy: .public)x\
            \(Int(images[0].pixelSize.height), privacy: .public) \
            \(images[0].mediaType, privacy: .public)
            """)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }

        try Self.checkHTTP(response: response, data: data)
        return try Self.decodeTicket(from: data)
    }

    /// Settings' "Test" button: the smallest real request that proves the key, the
    /// model name and the network all work, without spending anything meaningful.
    /// Returns the model the server actually served.
    func ping() async throws -> String {
        guard apiKey.nilIfEmpty != nil else { throw Failure.missingAPIKey }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "Reply with the single word: ready"]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }

        do {
            try Self.checkHTTP(response: response, data: data)
        } catch {
            // The Test button is the first thing anyone touches when drafting
            // misbehaves, so its outcome belongs in the log too.
            Log.drafting.error("ping failed: \(String(describing: error), privacy: .public)")
            throw error
        }

        let message = try? JSONDecoder().decode(MessageResponse.self, from: data)
        let served = message?.model ?? model
        Log.drafting.notice("ping ok, served by \(served, privacy: .public)")
        return served
    }

    // MARK: - Request

    /// Built as a dictionary rather than `Encodable` structs so the wire format stays
    /// legible against the API docs -- this body is the part most likely to need
    /// checking against them again.
    static func requestBody(
        model: String,
        images: [ImagePayload],
        note: String,
        context: CaptureContext,
        productContext: String? = nil,
        areas: [String] = []
    ) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            // A bug screenshot could trip a safety classifier; a refusal then routes to
            // another model instead of dead-ending the user's report.
            "fallbacks": "default",
            "output_config": [
                "effort": effort,
                "format": [
                    "type": "json_schema",
                    "schema": ticketSchema(areas: areas),
                ],
            ],
            "system": systemPrompt(productContext: productContext),
            "messages": [
                [
                    "role": "user",
                    "content": imageBlocks(images) + [
                        [
                            "type": "text",
                            "text": userPrompt(
                                note: note,
                                context: context,
                                captureCount: images.count
                            ),
                        ]
                    ],
                ]
            ],
        ]
    }

    /// One image block each, and -- when there's more than one -- a label before each,
    /// which is Anthropic's own guidance for multi-image requests: unlabelled images
    /// leave the model unable to refer to a particular one in the steps it writes.
    /// A single image is sent bare, exactly as before, so the common request is
    /// unchanged.
    static func imageBlocks(_ images: [ImagePayload]) -> [[String: Any]] {
        images.enumerated().flatMap { index, image -> [[String: Any]] in
            let source: [String: Any] = [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64,
                ],
            ]
            guard images.count > 1 else { return [source] }
            return [
                ["type": "text", "text": "Screenshot \(index + 1) of \(images.count):"],
                source,
            ]
        }
    }

    /// Every property required, `additionalProperties: false`. No `maxLength`,
    /// `minItems` or other constraints -- structured-output schemas don't support them.
    ///
    /// `areas` is the configured taxonomy. When it's empty the `area` property keeps its
    /// place but drops the `enum`: an empty `enum` would admit no value at all and fail
    /// every response, where an unconstrained string still gets the model's own word for
    /// where the bug is.
    static func ticketSchema(areas: [String] = []) -> [String: Any] {
        var area: [String: Any] = [
            "type": "string",
            "description": "The part of the product this belongs to.",
        ]
        if areas.isEmpty {
            area["description"] = "The part of the product this belongs to, as a short lowercase word."
        } else {
            area["enum"] = areas
        }

        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "title", "summary", "steps_to_reproduce",
                "expected", "actual", "area", "severity", "labels",
            ],
            "properties": [
                "title": [
                    "type": "string",
                    "description": "At most 80 characters. A specific statement of the broken behaviour, not an instruction. Good: \"Chat confirms section added but canvas doesn't update\". Bad: \"Fix the canvas\".",
                ],
                "summary": [
                    "type": "string",
                    "description": "One or two sentences of plain description.",
                ],
                "steps_to_reproduce": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Ordered steps. Infer what you reasonably can from the screenshot and note, and append \" (assumed)\" to any step you inferred rather than observed.",
                ],
                "expected": ["type": "string", "description": "What should have happened."],
                "actual": ["type": "string", "description": "What happened instead, as visible in the screenshot."],
                "area": area,
                "severity": [
                    "type": "string",
                    "enum": DraftedTicket.Severity.allCases.map(\.rawValue),
                    "description": "blocker: unusable, no workaround. major: core flow broken. minor: works with a workaround. cosmetic: visual only.",
                ],
                "labels": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "A few short lowercase labels, hyphenated. No spaces.",
                ],
            ],
        ]
    }

    /// The product-neutral half of the system prompt: who the ticket is for, and the
    /// rules that keep it honest. Deliberately not configurable -- this is the quality
    /// of the output, not a description of anyone's product.
    static let draftingRules = """
        You are writing for the engineers who will fix the bug. Be terse and factual.
        No pleasantries, no restating the obvious, no severity inflation.

        Rules you must not break:
        - Describe only what is visible in the screenshot or stated in the reporter's
          note. Never invent console errors, stack traces, network failures, error
          codes, or a technical cause. If you don't know why it happened, don't guess
          in writing -- say what is observable and stop.
        - Mark any reproduction step you inferred rather than observed by ending it with
          " (assumed)".
        - The title must be at most 80 characters and must state the broken behaviour
          rather than command a fix.
        - If the screenshot shows an error message, quote it exactly.
        """

    /// Added only when there's more than one screenshot. It says what the set is --
    /// one bug, in the reporter's order -- because the alternative is the model
    /// treating them as unrelated and writing three tickets' worth of summary into
    /// one. The ban on inventing what isn't visible still applies to all of them.
    static let multipleCaptureRules = """
        The screenshots are numbered in the order the reporter arranged them and all
        show the same bug. Read them as one sequence: what changes between them is
        usually the point. You may draw reproduction steps from that progression, but
        the rule above still holds -- anything you did not observe is marked
        " (assumed)". Refer to a specific image as "screenshot 2" where it helps.
        Write one ticket, not one per screenshot.
        """

    /// The configured product description, when there is one, then the rules verbatim.
    /// With nothing configured the rules stand alone rather than naming some product the
    /// reporter isn't using.
    static func systemPrompt(productContext: String? = nil) -> String {
        guard let context = productContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return draftingRules }
        return "\(context)\n\n\(draftingRules)"
    }

    static func userPrompt(note: String, context: CaptureContext) -> String {
        userPrompt(note: note, context: context, captureCount: 1)
    }

    static func userPrompt(note: String, context: CaptureContext, captureCount: Int) -> String {
        var lines: [String] = []

        let note = note.nilIfEmpty
        lines.append("Reporter's note: \(note ?? "(none given — work from the screenshot alone)")")

        lines.append("")
        lines.append("Captured context:")
        lines.append("- URL: \(context.url ?? "unknown")")
        if let title = context.pageTitle { lines.append("- Page title: \(title)") }
        if let env = context.env { lines.append("- Environment: \(env)") }
        if let browser = context.browserName { lines.append("- Browser: \(browser)") }
        lines.append("- Captured at: \(ISO8601DateFormatter().string(from: context.capturedAt))")
        lines.append("- \(context.osVersion)")
        if let resolution = context.screenResolution { lines.append("- Screen: \(resolution)") }

        lines.append("")
        if captureCount > 1 {
            lines.append(multipleCaptureRules)
            lines.append("")
            lines.append("Draft the ticket from the \(captureCount) screenshots and this context.")
        } else {
            lines.append("Draft the ticket from the screenshot and this context.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Response

    // Internal rather than private so the request shape and every failure branch
    // can be covered offline -- the live API needs a key the test run doesn't have.

    struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let type: String?
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
            case model
        }
    }

    struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let type: String?
            let message: String?
        }
        let error: APIError?
    }

    struct TicketPayload: Decodable {
        let title: String
        let summary: String
        let stepsToReproduce: [String]
        let expected: String
        let actual: String
        /// Optional so a schema that leaves the area out -- or a model that omits it --
        /// doesn't cost the whole draft.
        let area: String?
        let severity: String
        let labels: [String]

        enum CodingKeys: String, CodingKey {
            case title, summary, expected, actual, area, severity, labels
            case stepsToReproduce = "steps_to_reproduce"
        }
    }

    static func checkHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }

        let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let message = decoded?.error?.message
            ?? String(data: data, encoding: .utf8)?.nilIfEmpty
            ?? "no detail"

        switch http.statusCode {
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default:
            throw Failure.api(status: http.statusCode, type: decoded?.error?.type, message: message)
        }
    }

    static func decodeTicket(from data: Data) throws -> DraftedTicket {
        let message: MessageResponse
        do {
            message = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            throw Failure.undecodable(String(describing: error))
        }

        // Both of these must be checked before reading content: on a refusal the body
        // won't match the schema, and on max_tokens it'll be cut mid-JSON.
        if message.stopReason == "refusal" {
            throw Failure.refused(
                category: message.stopDetails?.category,
                explanation: message.stopDetails?.explanation
            )
        }
        if message.stopReason == "max_tokens" { throw Failure.truncated }

        guard let json = message.content.first(where: { $0.type == "text" })?.text?.nilIfEmpty else {
            throw Failure.noContent
        }

        let payload: TicketPayload
        do {
            payload = try JSONDecoder().decode(TicketPayload.self, from: Data(json.utf8))
        } catch {
            throw Failure.undecodable(String(describing: error))
        }

        if let served = message.model {
            Log.drafting.notice("drafted by \(served, privacy: .public)")
        }

        return DraftedTicket(
            title: payload.title,
            summary: payload.summary,
            stepsToReproduce: payload.stepsToReproduce,
            expected: payload.expected,
            actual: payload.actual,
            // An area outside the configured list is kept as the model gave it; only
            // severity, which is a fixed vocabulary, falls back.
            area: payload.area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            severity: DraftedTicket.Severity(rawValue: payload.severity) ?? .major,
            labels: payload.labels
        ).clampingTitle()
    }
}
