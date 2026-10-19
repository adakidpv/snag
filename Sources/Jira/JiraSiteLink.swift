import Foundation

/// What a pasted Jira link yields *before* any network call: the tenant, and the project
/// if the link happened to name one.
///
/// Onboarding asks for "any Jira link" because every link a user already has to hand --
/// the ticket they're looking at, the board they live in, or just the address bar --
/// carries the site, and most carry the project key too. Those two are the only things
/// readable without credentials. Every numeric id Jira needs for a create (`projectID`,
/// `issueTypeID`) has to be looked up authenticated, which is `JiraDiscovery`'s job.
///
/// The point of all this is that the user never types an id. The old setup had them
/// opening two REST endpoints in a browser and copying numbers out of JSON.
struct JiraSiteLink: Equatable {
    /// The `{site}` in `https://{site}.atlassian.net`.
    let site: String
    /// Present when the link named a project. Absent is fine and common -- onboarding
    /// then lists the projects the account can see instead of asking for a key.
    let projectKey: String?

    enum Failure: Error, LocalizedError, Equatable {
        case empty
        case unreadable
        case notJiraCloud(host: String)
        case noTenant(host: String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste a Jira link, or just your Jira address."
            case .unreadable:
                return "That doesn't look like a web address."
            case .notJiraCloud(let host):
                // Worth being explicit rather than failing later at the first API call:
                // the whole client assumes `{site}.atlassian.net`, so Server and Data
                // Center are out of scope, not merely unconfigured.
                return "\(host) isn't a Jira Cloud address. Snag works with Jira Cloud "
                    + "(an address ending in .atlassian.net), not Jira Server or Data Center."
            case .noTenant(let host):
                return "Couldn't read the site name from \(host). It should look like "
                    + "yourcompany.atlassian.net."
            }
        }
    }

    private static let cloudSuffix = ".atlassian.net"

    /// A project key on its own: starts with a letter, then uppercase alphanumerics and
    /// underscores. Deliberately the same rule as the half before the dash in
    /// `JiraKey.pattern`, so a key accepted here is one `JiraKey` would accept in a
    /// full issue key.
    private static let keyPattern = "^[A-Z][A-Z0-9_]*$"

    static func parse(_ raw: String?) throws -> JiraSiteLink {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw Failure.empty
        }

        // A bare host copied from the address bar has no scheme, and URLComponents would
        // read the whole string as a path and find no host at all.
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              var host = components.host?.lowercased().nilIfEmpty
        else { throw Failure.unreadable }

        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        // Pasting the bare domain is a near miss, not a wrong product -- say which
        // half is missing rather than claiming it isn't Jira Cloud.
        if host == "atlassian.net" { throw Failure.noTenant(host: host) }

        // Anchored on the suffix, so `acme.atlassian.net.example.com` is rejected rather
        // than mistaken for a tenant.
        guard host.hasSuffix(Self.cloudSuffix) else { throw Failure.notJiraCloud(host: host) }
        let site = String(host.dropLast(Self.cloudSuffix.count))
        guard !site.isEmpty, !site.contains(".") else { throw Failure.noTenant(host: host) }

        return JiraSiteLink(site: site, projectKey: Self.projectKey(in: components))
    }

    // MARK: - Finding the project

    /// Tried in order of how explicit the link is about the project. Every form here is
    /// one a user can actually end up with in the address bar.
    private static func projectKey(in components: URLComponents) -> String? {
        let segments = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []

        func queryValue(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value
        }

        func segment(after name: String) -> String? {
            guard let i = segments.firstIndex(where: { $0.lowercased() == name }),
                  segments.index(after: i) < segments.endIndex
            else { return nil }
            return segments[segments.index(after: i)]
        }

        // `/secure/RapidBoard.jspa?rapidView=1&projectKey=ABC`
        if let key = validate(queryValue("projectkey")) { return key }
        // `/jira/software/projects/ABC/boards/1`, `/jira/software/c/projects/ABC/...`,
        // `/jira/core/projects/ABC/board`, `/projects/ABC/issues`
        if let key = validate(segment(after: "projects")) { return key }
        // `/browse/ABC-412`
        if let key = projectKey(ofIssueKey: segment(after: "browse")) { return key }
        // A board link with an issue selected: `?selectedIssue=ABC-412`
        if let key = projectKey(ofIssueKey: queryValue("selectedissue")) { return key }
        return nil
    }

    private static func validate(_ candidate: String?) -> String? {
        guard let candidate = candidate?
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
            .nilIfEmpty,
            candidate.range(of: keyPattern, options: .regularExpression) != nil
        else { return nil }
        return candidate
    }

    /// `ABC-412` names project `ABC`. Routed through `JiraKey` so a fragment that isn't
    /// a whole issue key yields nothing rather than a plausible-looking wrong key.
    private static func projectKey(ofIssueKey candidate: String?) -> String? {
        guard let issueKey = JiraKey.normalize(candidate),
              let dash = issueKey.lastIndex(of: "-")
        else { return nil }
        return validate(String(issueKey[issueKey.startIndex..<dash]))
    }
}
