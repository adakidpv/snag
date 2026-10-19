import Foundation
import Observation

/// The state machine behind the board setup sheet.
///
/// Split from the view for the same reason `ReportSession` is: the interesting part --
/// which step is reachable, which failure the user is shown, and what a finished setup
/// turns into -- is logic, and worth testing without a window or a Jira tenant.
///
/// The flow exists to make one promise good: **nobody types a numeric id.** A pasted
/// link gives the site and usually the project key; the API token turns those into the
/// ids Jira needs. The old path had the user opening two REST endpoints in a browser
/// and copying numbers out of raw JSON.
@Observable
@MainActor
final class BoardSetupModel {
    enum Step: Int, CaseIterable {
        case link, connect, project, review

        var title: String {
            switch self {
            case .link: return "Your Jira"
            case .connect: return "Connect"
            case .project: return "Project"
            case .review: return "Finish"
            }
        }
    }

    private(set) var step: Step = .link
    private(set) var isWorking = false
    /// The one thing that went wrong at the current step, in the user's terms.
    private(set) var errorMessage: String?

    // MARK: - Step 1: the pasted link

    var pastedLink = ""
    private(set) var link: JiraSiteLink?

    // MARK: - Step 2: credentials

    var email = ""
    var token = ""
    private(set) var account: JiraDiscovery.Account?
    var mode: Board.Mode = .restAPI

    // MARK: - Step 3: the project

    var projectQuery = ""
    private(set) var projects: [JiraDiscovery.Project] = []
    private(set) var project: JiraDiscovery.Project?
    var issueTypeID: String?

    // MARK: - Step 4: review

    var name = ""
    /// Snag only raises a toast on a watched domain, and a fresh install watches none --
    /// so setup has to offer to add one, or the user finishes and sees nothing happen.
    var watchDomain = ""
    private(set) var unfillableFields: [JiraDiscovery.RequiredField] = []
    /// Set when the required-field check itself couldn't run. Never fatal: it's a
    /// warning about Jira's configuration, not a step that has to succeed.
    private(set) var fieldCheckNote: String?

    /// Injected so the flow can be driven end to end against stubbed HTTP.
    var session: URLSession = .shared

    init() {}

    private var discovery: JiraDiscovery? {
        guard let site = link?.site else { return nil }
        return JiraDiscovery(site: site, accountEmail: email, apiToken: token, session: session)
    }

    // MARK: - Step 1

    func submitLink() {
        errorMessage = nil
        do {
            link = try JiraSiteLink.parse(pastedLink)
            step = .connect
        } catch {
            link = nil
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Step 2

    /// Validates the credentials and prefills the account email in one request, so the
    /// user isn't asked to confirm something Jira already knows.
    func connect() async {
        guard let discovery else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let account = try await discovery.me()
            self.account = account
            // Atlassian lets a profile hide its email. If it did, keep whatever the user
            // typed rather than blanking the field.
            if let exposed = account.email { email = exposed }
            step = .project
            await loadProject()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Some tenants block API tokens outright. Rather than dead-end, setup hands the
    /// user to the ordinary board editor with the site and project key already filled
    /// in, where the prefilled-URL mode lives.
    func partialBoardForManualSetup() -> Board {
        Board(
            name: name.nilIfEmpty ?? link?.projectKey ?? "New board",
            site: link?.site ?? "",
            mode: .prefilledURL
        )
    }

    // MARK: - Step 3

    /// Resolves the key the link carried, or lists what the account can see when it
    /// carried none.
    func loadProject() async {
        guard let discovery else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            if let key = link?.projectKey {
                select(try await discovery.project(key: key))
            } else {
                projects = try await discovery.projects()
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func searchProjects() async {
        guard let discovery else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            projects = try await discovery.projects(matching: projectQuery)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Picking a project chooses its Bug type too, and names the board after it -- all
    /// three are editable afterwards, but none should have to be.
    func select(_ project: JiraDiscovery.Project) {
        self.project = project
        issueTypeID = project.likelyBugType?.id
        if name.nilIfEmpty == nil { name = project.name }
    }

    /// Steps back from a resolved project to the full list, for when the pasted link
    /// pointed at the wrong one.
    func chooseAnotherProject() async {
        project = nil
        issueTypeID = nil
        await searchProjects()
    }

    var canLeaveProjectStep: Bool {
        project != nil && issueTypeID?.nilIfEmpty != nil
    }

    // MARK: - Step 4

    /// Runs the create-screen check and moves on regardless of its outcome. A tenant
    /// with a mandatory custom field on its Bug screen rejects every create Snag makes,
    /// and the old failure mode was finding that out while holding a real bug.
    func reviewAfterCheckingFields() async {
        guard let discovery, let project, let issueTypeID else { return }
        errorMessage = nil
        fieldCheckNote = nil
        unfillableFields = []
        isWorking = true
        defer {
            isWorking = false
            step = .review
        }

        do {
            unfillableFields = try await discovery.unfillableRequiredFields(
                projectKey: project.key,
                issueTypeID: issueTypeID
            )
        } catch {
            fieldCheckNote = "Couldn't check this project's required fields: "
                + Self.message(for: error)
        }
    }

    /// Nil until every id is resolved, so the sheet can't finish half-configured.
    func finishedBoard() -> Board? {
        guard let link, let project, let issueTypeID = issueTypeID?.nilIfEmpty else { return nil }
        return Board(
            name: name.nilIfEmpty ?? project.name,
            site: link.site,
            projectID: project.id,
            issueTypeID: issueTypeID,
            mode: mode,
            accountEmail: email
        )
    }

    /// The domain to start watching, normalised the same way the Domains tab does it.
    /// Nil when the user left it empty, which is allowed -- they can add it later.
    func domainToWatch() -> String? {
        DomainRules.normalize(watchDomain)
    }

    // MARK: - Navigation

    func back() {
        errorMessage = nil
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
