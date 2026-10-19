import SwiftUI

/// Setup for a new board, as four steps that each prove themselves before the next.
///
/// The shape of this is dictated by what Jira will tell you and when: the site and
/// project key are readable from a pasted link, and everything else needs credentials.
/// So the link comes first, the token second, and the ids are never asked for at all.
struct BoardSetupWizard: View {
    @Bindable var settings: AppSettings
    /// The finished board's id, so the Boards list can select what was just added.
    let onFinish: (UUID) -> Void
    /// Taken when the tenant blocks API tokens: a part-filled board for the ordinary
    /// editor, rather than a dead end.
    let onManualSetup: (Board) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = BoardSetupModel()

    private static let tokenURL = URL(
        string: "https://id.atlassian.com/manage-profile/security/api-tokens"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            steps
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
    }

    // MARK: - Chrome

    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(BoardSetupModel.Step.allCases, id: \.rawValue) { step in
                let done = step.rawValue < model.step.rawValue
                Label(step.title, systemImage: done ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(step == model.step ? .primary : .secondary)
                    .symbolVariant(step == model.step ? .fill : .none)
                if step != BoardSetupModel.Step.allCases.last {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if model.step != .link {
                Button("Back") { model.back() }.disabled(model.isWorking)
            }
            Button(model.isWorking ? "Working…" : primaryTitle) { primaryAction() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking || !primaryEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var primaryTitle: String {
        switch model.step {
        case .link: return "Continue"
        case .connect: return "Connect"
        case .project: return "Continue"
        case .review: return "Add board"
        }
    }

    private var primaryEnabled: Bool {
        switch model.step {
        case .link: return model.pastedLink.nilIfEmpty != nil
        case .connect: return model.email.nilIfEmpty != nil && model.token.nilIfEmpty != nil
        case .project: return model.canLeaveProjectStep
        case .review: return model.finishedBoard() != nil
        }
    }

    private func primaryAction() {
        switch model.step {
        case .link: model.submitLink()
        case .connect: Task { await model.connect() }
        case .project: Task { await model.reviewAfterCheckingFields() }
        case .review: finish()
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .link: linkStep
        case .connect: connectStep
        case .project: projectStep
        case .review: reviewStep
        }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste anything from Jira").font(.headline)
            Text("A ticket, a board, or just your Jira address — whatever you already have open. Snag reads the site and the project out of it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(
                "Jira link",
                text: $model.pastedLink,
                prompt: Text("https://yourcompany.atlassian.net/browse/BUG-412")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.submitLink() }
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to \(model.link?.site ?? "Jira")").font(.headline)
            if let key = model.link?.projectKey {
                Text("Found project **\(key)**. Connecting confirms it and fills in the ids Jira needs.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No project in that link — once connected, you can pick from the projects your account can see.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Account email", text: $model.email, prompt: Text("you@example.com"))
                SecureField("API token", text: $model.token)
            }
            .formStyle(.columns)

            HStack {
                Button("Create a token…") { openURL(Self.tokenURL) }
                Text("The token isn't your Atlassian password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let account = model.account {
                Label("Connected as \(account.displayName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Divider().padding(.vertical, 4)

            Button("My organisation doesn't allow API tokens") {
                onManualSetup(model.partialBoardForManualSetup())
                dismiss()
            }
            .buttonStyle(.link)
            Text("Sets the board up to open a prefilled Jira create screen instead. You'll need to fill in the two ids by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var projectStep: some View {
        if let project = model.project {
            VStack(alignment: .leading, spacing: 10) {
                Text("File bugs into").font(.headline)
                Label("\(project.key) — \(project.name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Picker("Issue type", selection: $model.issueTypeID) {
                    ForEach(project.issueTypes.filter { !$0.isSubtask }) { type in
                        Text(type.name).tag(Optional(type.id))
                    }
                }
                .frame(maxWidth: 280)

                Text("Snag never shows you a project or issue type id — it reads them from Jira and keeps them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose a different project") {
                    Task { await model.chooseAnotherProject() }
                }
                .buttonStyle(.link)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick a project").font(.headline)
                HStack {
                    TextField("Search", text: $model.projectQuery, prompt: Text("Search projects"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.searchProjects() } }
                    Button("Search") { Task { await model.searchProjects() } }
                }
                if model.projects.isEmpty, !model.isWorking {
                    Text("No projects to show. Search by name or key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.projects) { project in
                    Button {
                        model.select(project)
                    } label: {
                        HStack {
                            Text(project.key).monospaced().foregroundStyle(.secondary)
                            Text(project.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to add").font(.headline)

            Form {
                TextField("Board name", text: $model.name)
                TextField(
                    "Watch this domain",
                    text: $model.watchDomain,
                    prompt: Text("app.example.com")
                )
            }
            .formStyle(.columns)

            Text("Snag only offers to report a screenshot taken on a watched domain. Leave it empty and add domains later in Settings › Domains — until one is set, no toast appears.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.unfillableFields.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "This project requires \(model.unfillableFields.count == 1 ? "a field" : "fields") Snag can't fill",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    ForEach(model.unfillableFields, id: \.id) { field in
                        Text("• \(field.name)").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Filing will be rejected until someone makes these optional on the Bug screen, or gives them a default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.fieldCheckNote == nil {
                Label("Nothing on this project's create screen will block filing.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if let note = model.fieldCheckNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Finishing

    private func finish() {
        guard let board = model.finishedBoard() else { return }
        settings.upsert(board: board)

        if board.mode == .restAPI, let token = model.token.nilIfEmpty {
            try? Keychain.write(token, account: Keychain.Account.jiraToken(boardID: board.id))
        }

        if let domain = model.domainToWatch() {
            var rules = settings.domainRules
            if !rules.watchedDomains.contains(domain) {
                rules.watchedDomains.append(domain)
            }
            settings.domainRules = rules
        }

        onFinish(board.id)
        dismiss()
    }
}
