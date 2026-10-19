import Foundation

/// A Jira destination. `mode` decides how filing happens: the REST API creates the
/// issue and attaches the screenshot itself, while `prefilledURL` falls back to opening
/// a create screen with the fields filled in -- kept for tenants where an API token
/// can't be issued.
///
/// A board also carries the product-specific half of the drafting configuration
/// (`productContext` and `areas`). That scope is deliberate: one machine may file to
/// several teams' boards, and each of those teams has its own product to describe and
/// its own area taxonomy to classify into. Drafting always happens with a board
/// selected, so the Report panel has the right pair to hand.
struct Board: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// The `{site}` in `https://{site}.atlassian.net`.
    var site: String
    var projectID: String
    var issueTypeID: String
    var defaultLabels: [String]
    var mode: Mode
    /// Atlassian account email; the other half of Basic auth, with the API token held
    /// in the Keychain. Unused in `prefilledURL` mode.
    var accountEmail: String
    /// Free text about the product this board's bugs are in, placed at the top of the
    /// system prompt. Empty is fine: drafting then runs on the product-neutral rules
    /// alone and still produces a usable ticket.
    var productContext: String
    /// The area taxonomy, in the order it should be offered. Becomes the `enum` for the
    /// drafted `area` and the options in the Report panel's picker. Empty is fine: the
    /// schema then leaves the area unconstrained.
    var areas: [String]

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case restAPI
        case prefilledURL
        var id: String { rawValue }
        var label: String {
            switch self {
            case .restAPI: return "REST API (files and attaches automatically)"
            case .prefilledURL: return "Prefilled URL (opens a create screen)"
            }
        }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        site: String = "",
        projectID: String = "",
        issueTypeID: String = "",
        defaultLabels: [String] = [],
        mode: Mode = .restAPI,
        accountEmail: String = "",
        productContext: String = "",
        areas: [String] = []
    ) {
        self.id = id
        self.name = name
        self.site = site
        self.projectID = projectID
        self.issueTypeID = issueTypeID
        self.defaultLabels = defaultLabels
        self.mode = mode
        self.accountEmail = accountEmail
        self.productContext = productContext
        self.areas = areas
    }

    /// Decoded field by field with fallbacks, for the same reason `AppSettings.Stored`
    /// is: a board written by an older version has no `productContext` or `areas` key,
    /// and the synthesized initialiser would throw on it. That throw would take the
    /// whole `boards` array down with it and silently reset the user's configuration.
    ///
    /// A board whose `id` can't be read gets a fresh one rather than failing the array.
    /// Its Keychain token is then orphaned and has to be re-entered -- a far smaller
    /// loss than every board on the machine.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? ""
        site = (try? container.decodeIfPresent(String.self, forKey: .site)).flatMap { $0 } ?? ""
        projectID = (try? container.decodeIfPresent(String.self, forKey: .projectID)).flatMap { $0 } ?? ""
        issueTypeID = (try? container.decodeIfPresent(String.self, forKey: .issueTypeID)).flatMap { $0 } ?? ""
        defaultLabels = (try? container.decodeIfPresent([String].self, forKey: .defaultLabels)).flatMap { $0 } ?? []
        mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)).flatMap { $0 } ?? .restAPI
        accountEmail = (try? container.decodeIfPresent(String.self, forKey: .accountEmail)).flatMap { $0 } ?? ""
        productContext = (try? container.decodeIfPresent(String.self, forKey: .productContext))
            .flatMap { $0 } ?? ""
        areas = (try? container.decodeIfPresent([String].self, forKey: .areas))
            .flatMap { $0 } ?? []
    }

    var baseURL: String { "https://\(site).atlassian.net" }

    func browseURL(forKey key: String) -> URL? {
        URL(string: "\(baseURL)/browse/\(key)")
    }

    /// Trimmed, blanks dropped, duplicates removed, order kept. The raw list is typed
    /// as free text, and it ends up in a JSON-schema `enum`, where a blank or a repeat
    /// is at best meaningless.
    var normalizedAreas: [String] {
        var seen = Set<String>()
        return areas.compactMap { area in
            guard let trimmed = area.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// What must be filled in before filing can be attempted, so the Report panel can
    /// say which field is missing instead of failing at the network call.
    var configurationProblem: String? {
        if site.trimmingCharacters(in: .whitespaces).isEmpty { return "Jira site is not set" }
        if projectID.trimmingCharacters(in: .whitespaces).isEmpty { return "Project ID is not set" }
        if issueTypeID.trimmingCharacters(in: .whitespaces).isEmpty { return "Issue type ID is not set" }
        if mode == .restAPI, accountEmail.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Atlassian account email is not set"
        }
        return nil
    }
}
