import Foundation

/// Creates issues through the Jira Cloud REST API and attaches the screenshot.
///
/// Chosen over the prefilled-URL handoff because it actually finishes the job: the
/// issue exists when the call returns, the screenshot is on it, and the issue key comes
/// back -- so the user never has to paste it in by hand.
///
/// Auth is HTTP Basic with the Atlassian account email as the username and an API token
/// as the password; the token lives in the Keychain, scoped per board.
struct JiraClient {
    let site: String
    let accountEmail: String
    let apiToken: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 60

    struct CreatedIssue {
        let id: String
        let key: String
    }

    enum Failure: Error, LocalizedError {
        case missingConfiguration(String)
        case offline(String)
        case unauthorized
        case forbidden
        /// Jira returns field-level reasons for a rejected create; they're the most
        /// useful thing to show, so they're carried through verbatim.
        case rejected(status: Int, messages: [String])
        case unexpected(status: Int, body: String)
        case attachmentFailed(issueKey: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration(let what):
                return "\(what). Fix it in Settings › Boards."
            case .offline(let detail):
                return "Couldn't reach Jira: \(detail)"
            case .unauthorized:
                return "Jira rejected the email and API token. Check them in Settings › Boards."
            case .forbidden:
                return "That Jira account isn't allowed to create issues in this project."
            case .rejected(let status, let messages):
                let detail = messages.isEmpty ? "no detail given" : messages.joined(separator: "; ")
                return "Jira wouldn't create the issue (\(status)): \(detail)"
            case .unexpected(let status, let body):
                return "Unexpected Jira response \(status): \(body)"
            case .attachmentFailed(let key, let reason):
                // Deliberately not a plain failure: the ticket exists, so losing the
                // attachment must not look like losing the ticket.
                return "Created \(key), but attaching the screenshot failed: \(reason)"
            }
        }
    }

    private var baseURL: String { "https://\(site).atlassian.net" }

    private var authorizationHeader: String {
        let credentials = "\(accountEmail):\(apiToken)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    // MARK: - Creating

    /// Creates the issue and attaches the captures, primary first.
    ///
    /// The two steps are reported separately on purpose: if an attachment fails the
    /// issue still exists, and the caller needs the key so the user isn't left thinking
    /// nothing was filed.
    ///
    /// Attachments go up one at a time rather than as one multi-file request, so a
    /// failure can say which capture and how many made it -- and so that one oversized
    /// capture doesn't take the others down with it.
    func file(
        title: String,
        body: TicketBody,
        labels: [String],
        projectID: String,
        issueTypeID: String,
        attachments: [URL]
    ) async throws -> CreatedIssue {
        guard site.nilIfEmpty != nil else { throw Failure.missingConfiguration("Jira site is not set") }
        guard accountEmail.nilIfEmpty != nil else { throw Failure.missingConfiguration("Atlassian account email is not set") }
        guard apiToken.nilIfEmpty != nil else { throw Failure.missingConfiguration("No Jira API token stored for this board") }
        guard projectID.nilIfEmpty != nil else { throw Failure.missingConfiguration("Project ID is not set") }
        guard issueTypeID.nilIfEmpty != nil else { throw Failure.missingConfiguration("Issue type ID is not set") }

        let issue = try await createIssue(
            title: title,
            body: body,
            labels: labels,
            projectID: projectID,
            issueTypeID: issueTypeID
        )
        Log.jira.notice("created \(issue.key, privacy: .public)")

        var attached = 0
        for attachment in attachments {
            do {
                try await attach(file: attachment, to: issue.key)
                attached += 1
                Log.jira.notice("attached \(attachment.lastPathComponent, privacy: .public) to \(issue.key, privacy: .public)")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.jira.error("attach failed for \(issue.key, privacy: .public): \(reason, privacy: .public)")
                throw Failure.attachmentFailed(
                    issueKey: issue.key,
                    reason: attachments.count > 1
                        ? "\(reason) \(attached) of \(attachments.count) attached."
                        : reason
                )
            }
        }
        return issue
    }

    static func createIssueBody(
        title: String,
        body: TicketBody,
        labels: [String],
        projectID: String,
        issueTypeID: String
    ) -> [String: Any] {
        [
            "fields": [
                "project": ["id": projectID],
                "issuetype": ["id": issueTypeID],
                "summary": title,
                // v3 takes rich text as ADF, never a string.
                "description": ADFBuilder.document(for: body),
                "labels": TicketBody.sanitizeLabels(labels),
            ]
        ]
    }

    private func createIssue(
        title: String,
        body: TicketBody,
        labels: [String],
        projectID: String,
        issueTypeID: String
    ) async throws -> CreatedIssue {
        var request = URLRequest(url: URL(string: "\(baseURL)/rest/api/3/issue")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.createIssueBody(
                title: title,
                body: body,
                labels: labels,
                projectID: projectID,
                issueTypeID: issueTypeID
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }

        try Self.checkResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String
        else {
            throw Failure.unexpected(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: String(data: data, encoding: .utf8) ?? "unreadable"
            )
        }
        return CreatedIssue(id: json["id"] as? String ?? "", key: key)
    }

    // MARK: - Attaching

    private func attach(file url: URL, to issueKey: String) async throws {
        let endpoint = URL(string: "\(baseURL)/rest/api/3/issue/\(issueKey)/attachments")!
        let boundary = "snag-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Jira's XSRF check rejects this endpoint without it.
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")

        let fileData = try Data(contentsOf: url)
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            filename: Self.attachmentFilename(for: url),
            mimeType: Self.mimeType(for: url),
            fileData: fileData
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }
        try Self.checkResponse(response, data: data)
    }

    /// The field name must be `file`; Jira ignores anything else.
    static func multipartBody(
        boundary: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Capture files are named by UUID in the library, which is meaningless in a
    /// ticket -- give the attachment a name a human can read.
    static func attachmentFilename(for url: URL) -> String {
        let ext = url.pathExtension.nilIfEmpty ?? "png"
        let stamp = DateFormatter.attachmentStamp.string(from: Date())
        return "snag-\(stamp).\(ext)"
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Responses

    static func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }

        switch http.statusCode {
        case 401: throw Failure.unauthorized
        case 403: throw Failure.forbidden
        default:
            throw Failure.rejected(status: http.statusCode, messages: parseErrorMessages(data))
        }
    }

    /// Jira reports problems two ways: a list of general messages, and a map of
    /// field name to message. Both matter -- the field map is what tells you a required
    /// custom field is missing, which is the most likely reason a create is rejected.
    static func parseErrorMessages(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.nilIfEmpty.map { [$0] } ?? []
        }

        var messages: [String] = []
        if let general = json["errorMessages"] as? [String] {
            messages.append(contentsOf: general.compactMap { $0.nilIfEmpty })
        }
        if let fields = json["errors"] as? [String: Any] {
            for (field, message) in fields.sorted(by: { $0.key < $1.key }) {
                messages.append("\(field): \(message)")
            }
        }
        return messages
    }
}

private extension DateFormatter {
    static let attachmentStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
