import Foundation

/// The authenticated half of onboarding: everything that can only be learned by asking
/// Jira, which is everything except the site and the project key.
///
/// This exists so the user never types an id. A pasted link gives the site and usually
/// the project key (`JiraSiteLink`); an API token turns those into the numeric
/// `projectID` and `issueTypeID` a create actually needs, confirms who the credentials
/// belong to, and -- the part that saves a real evening -- says up front whether the
/// project's Bug screen demands a field Snag can't fill.
///
/// Read-only by construction: every call here is a GET. Creating issues stays in
/// `JiraClient`.
struct JiraDiscovery {
    let site: String
    let accountEmail: String
    let apiToken: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 30

    // MARK: - What comes back

    struct Account: Equatable {
        let accountID: String
        let displayName: String
        /// Absent when the profile hides it, which Atlassian allows and many tenants
        /// enforce. Onboarding keeps asking for the email in that case instead of
        /// pretending it knows.
        let email: String?
    }

    struct IssueType: Equatable, Identifiable {
        let id: String
        let name: String
        let isSubtask: Bool
    }

    struct Project: Equatable, Identifiable {
        let id: String
        let key: String
        let name: String
        let issueTypes: [IssueType]

        /// Snag files bugs, so this is what onboarding should preselect. Falls back to
        /// the first non-subtask type for the tenants that renamed or removed "Bug" --
        /// a subtask type can't be created standalone, so it's never a useful default.
        var likelyBugType: IssueType? {
            issueTypes.first { $0.name.lowercased() == "bug" && !$0.isSubtask }
                ?? issueTypes.first { !$0.isSubtask }
        }
    }

    struct RequiredField: Equatable {
        let id: String
        let name: String
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidConfiguration(String)
        case offline(String)
        case unauthorized
        case forbidden
        case projectNotFound(key: String)
        case unreadable(String)
        case unexpected(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let what):
                return what
            case .offline(let detail):
                return "Couldn't reach Jira: \(detail)"
            case .unauthorized:
                // The single most common setup mistake, so the message names it.
                return "Jira rejected that email and API token. The token isn't your "
                    + "Atlassian password — create one at id.atlassian.com › Security › "
                    + "API tokens."
            case .forbidden:
                return "That account reached Jira but isn't allowed to see this. Whoever "
                    + "administers your Jira site can grant access to the project."
            case .projectNotFound(let key):
                return "No project with key \(key) on this site. Pick one from the list instead."
            case .unreadable(let what):
                return "Jira's reply couldn't be read: \(what)"
            case .unexpected(let status, let detail):
                return "Unexpected Jira response \(status): \(detail)"
            }
        }
    }

    // MARK: - Calls

    /// Validates the credentials and says who they belong to. Doubles as the way the
    /// account email gets prefilled rather than typed.
    func me() async throws -> Account {
        try Self.account(in: try await get("/rest/api/3/myself"))
    }

    /// One request resolves both ids: the project response carries its own numeric id
    /// and its issue types, so there's no second lookup to find "Bug".
    func project(key rawKey: String) async throws -> Project {
        let key = rawKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { throw Failure.invalidConfiguration("No project key given") }
        do {
            let data = try await get(
                "/rest/api/3/project/\(key)",
                query: [URLQueryItem(name: "expand", value: "issueTypes")]
            )
            guard let project = Self.project(in: data) else {
                throw Failure.unreadable("no project in the response for \(key)")
            }
            return project
        } catch Failure.unexpected(let status, _) where status == 404 {
            throw Failure.projectNotFound(key: key)
        }
    }

    /// For when the pasted link named no project: let the user pick from what their
    /// account can actually see, rather than asking them to produce a key.
    func projects(matching query: String? = nil) async throws -> [Project] {
        var items = [
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "expand", value: "issueTypes"),
        ]
        if let query = query?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        return Self.projects(in: try await get("/rest/api/3/project/search", query: items))
    }

    /// Required fields on this project's chosen issue type that Snag won't be sending.
    ///
    /// A tenant with a mandatory "Severity" or "Component" on its Bug screen rejects
    /// every create Snag makes, and the old failure mode was discovering that at the
    /// moment you had a real bug to file. Empty is the happy answer.
    func unfillableRequiredFields(
        projectKey: String,
        issueTypeID: String
    ) async throws -> [RequiredField] {
        let key = projectKey.trimmingCharacters(in: .whitespaces).uppercased()
        let data = try await get(
            "/rest/api/3/issue/createmeta/\(key)/issuetypes/\(issueTypeID)"
        )
        return Self.unfillableRequiredFields(in: data)
    }

    // MARK: - Request

    private var baseURL: String { "https://\(site).atlassian.net" }

    private var authorizationHeader: String {
        let credentials = "\(accountEmail):\(apiToken)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard site.nilIfEmpty != nil else {
            throw Failure.invalidConfiguration("Jira site is not set")
        }
        guard accountEmail.nilIfEmpty != nil else {
            throw Failure.invalidConfiguration("Atlassian account email is not set")
        }
        guard apiToken.nilIfEmpty != nil else {
            throw Failure.invalidConfiguration("No Jira API token entered")
        }

        var components = URLComponents(string: baseURL + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw Failure.invalidConfiguration(
                "\"\(site)\" isn't a usable Jira site name — it should be just the "
                    + "subdomain, like yourcompany."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            switch http.statusCode {
            case 401: throw Failure.unauthorized
            case 403: throw Failure.forbidden
            default:
                // Reuses the create path's parser: Jira reports problems the same way
                // whichever endpoint refused.
                let messages = JiraClient.parseErrorMessages(data)
                throw Failure.unexpected(
                    status: http.statusCode,
                    detail: messages.isEmpty ? "no detail given" : messages.joined(separator: "; ")
                )
            }
        }
        return data
    }

    // MARK: - Responses

    static func account(in data: Data) throws -> Account {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = string(json["accountId"])
        else { throw Failure.unreadable("no account in the response") }

        return Account(
            accountID: accountID,
            displayName: string(json["displayName"]) ?? "",
            email: string(json["emailAddress"])?.nilIfEmpty
        )
    }

    static func project(in data: Data) -> Project? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return project(from: json)
    }

    static func projects(in data: Data) -> [Project] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[String: Any]]
        else { return [] }
        return values.compactMap(project(from:))
    }

    private static func project(from json: [String: Any]) -> Project? {
        guard let id = string(json["id"]), let key = string(json["key"]) else { return nil }

        let types = (json["issueTypes"] as? [[String: Any]] ?? []).compactMap { raw -> IssueType? in
            guard let id = string(raw["id"]), let name = string(raw["name"]) else { return nil }
            return IssueType(id: id, name: name, isSubtask: raw["subtask"] as? Bool ?? false)
        }

        return Project(id: id, key: key, name: string(json["name"]) ?? key, issueTypes: types)
    }

    /// The fields Snag populates itself on a create. Must stay in step with
    /// `JiraClient.createIssueBody` -- a field dropped from there but left here would
    /// turn a real warning into silence.
    static let fieldsSnagFills: Set<String> = [
        "project", "issuetype", "summary", "description", "labels",
    ]

    /// Atlassian's createmeta has carried its field list under `values`, `fields` and
    /// `results` across revisions, and the older deprecated endpoint returned `fields`
    /// as a map keyed by field id rather than an array. All of those are accepted,
    /// because reading the wrong key here doesn't fail loudly: it reports no required
    /// fields, which is precisely the warning the user needed.
    static func unfillableRequiredFields(in data: Data) -> [RequiredField] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var entries: [[String: Any]] = []
        for key in ["values", "fields", "results"] {
            if let array = json[key] as? [[String: Any]] {
                entries = array
                break
            }
            if let map = json[key] as? [String: Any] {
                entries = map.compactMap { id, value in
                    guard var field = value as? [String: Any] else { return nil }
                    if field["fieldId"] == nil { field["fieldId"] = id }
                    return field
                }
                break
            }
        }

        return entries
            .compactMap { field -> RequiredField? in
                guard field["required"] as? Bool == true,
                      field["hasDefaultValue"] as? Bool != true,
                      let id = string(field["fieldId"]) ?? string(field["key"]),
                      !fieldsSnagFills.contains(id)
                else { return nil }
                return RequiredField(id: id, name: string(field["name"]) ?? id)
            }
            .sorted { $0.id < $1.id }
    }

    /// Jira is inconsistent about quoting numeric ids, so accept either.
    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
