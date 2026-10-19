import KeyboardShortcuts
import SwiftUI

/// Settings. Everything the brief lists, in four tabs so no single pane sprawls.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: CaptureCoordinator

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
            DraftingSettingsTab(settings: settings)
                .tabItem { Label("Drafting", systemImage: "sparkles") }
            DomainsSettingsTab(settings: settings)
                .tabItem { Label("Domains", systemImage: "globe") }
            BoardsSettingsTab(settings: settings)
                .tabItem { Label("Boards", systemImage: "square.stack") }
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings
    let coordinator: CaptureCoordinator

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var floatingThumbnail = FloatingThumbnail.isEnabled
    @State private var launchError: String?
    @State private var permissionResult: String?
    @State private var pendingBundleID: String?
    @State private var browsers: [(bundleID: String, name: String, permission: BrowserContextReader.Permission)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Show a toast when I capture a watched page", isOn: $settings.toastEnabled)
                KeyboardShortcuts.Recorder("Open the Report panel:", name: .openReport)
            }

            Section {
                Toggle("Launch Snag at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchError = nil
                        } catch {
                            // Registration fails when the app isn't somewhere the
                            // system will launch from -- say so rather than letting the
                            // toggle silently snap back.
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = LaunchAtLogin.statusNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Capture speed") {
                // The one setting here that isn't Snag's own: it belongs to macOS, and
                // it's offered because it's what stands between taking a screenshot and
                // Snag being able to see it. Measured 5.7s on, 0.3s off.
                Toggle("Show macOS's floating thumbnail after a capture", isOn: $floatingThumbnail)
                    .onChange(of: floatingThumbnail) { _, newValue in
                        FloatingThumbnail.setEnabled(newValue)
                        floatingThumbnail = FloatingThumbnail.isEnabled
                    }
                Text(floatingThumbnail
                     ? "macOS holds each capture on screen for about five seconds before writing the file, so the toast can't appear until then. Switch it off and the toast arrives in well under a second. Snag still reads the page you were on at the moment you captured, either way."
                     : "Captures are written straight away, so the toast arrives in well under a second. The cost is the thumbnail's own tricks: clicking it to mark up, and dragging it into another app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Capture folder") {
                Text(coordinator.watchedFolder?.path ?? "Not watching")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("Read from macOS's own screenshot location. Change it with ⌘⇧5 › Options.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Browser access") {
                // Snag never raises the Automation prompt while handling a capture --
                // an unanswered dialog would block the Apple Event and cost the
                // capture. This is where the user asks for it deliberately.
                //
                // Each browser is targeted by bundle id, not by whichever app is
                // frontmost: clicking a button here necessarily makes *Snag* frontmost,
                // so a frontmost-based grant could never succeed.
                if browsers.isEmpty {
                    Text("No supported browser is running. Open Chrome or Safari, then reopen Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(browsers, id: \.bundleID) { browser in
                        HStack {
                            Text(browser.name)
                            Spacer()
                            permissionLabel(for: browser.permission)
                            if browser.permission != .permitted {
                                Button(pendingBundleID == browser.bundleID ? "Waiting…" : "Grant") {
                                    Task { await grant(bundleID: browser.bundleID) }
                                }
                                .disabled(pendingBundleID != nil || browser.permission == .appNotRunning)
                            }
                        }
                    }
                }

                Text(permissionResult ?? "Snag reads the address of the frontmost browser tab so it can tell which page a capture came from. Approve the prompt macOS shows — you can stay in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshBrowsers() }
    }

    @ViewBuilder
    private func permissionLabel(for permission: BrowserContextReader.Permission) -> some View {
        switch permission {
        case .permitted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .notDetermined:
            Text("Not asked yet").font(.caption).foregroundStyle(.secondary)
        case .appNotRunning:
            Text("Not running").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func grant(bundleID: String) async {
        pendingBundleID = bundleID
        defer { pendingBundleID = nil }

        let result = await coordinator.requestBrowserPermission(forBundleID: bundleID)
        let name = browsers.first { $0.bundleID == bundleID }?.name ?? bundleID

        switch result {
        case .permitted:
            permissionResult = "\(name) is allowed — captures will carry the page URL."
        case .denied:
            // macOS only prompts once; after a refusal it has to be changed by hand.
            permissionResult = "\(name) was refused. Turn Snag on for it in System Settings › Privacy & Security › Automation."
        case .appNotRunning:
            permissionResult = "\(name) isn't running any more."
        case .notDetermined:
            permissionResult = "No answer from \(name). Try again, or grant it in System Settings › Privacy & Security › Automation."
        }
        refreshBrowsers()
    }

    private func refreshBrowsers() {
        browsers = coordinator.browserPermissions()
    }
}

// MARK: - Drafting

private struct DraftingSettingsTab: View {
    @Bindable var settings: AppSettings

    @State private var apiKey = ""
    @State private var hasStoredKey = Keychain.has(account: Keychain.Account.anthropicAPIKey)
    @State private var testState = TestState.idle

    private enum TestState: Equatable {
        case idle, running, passed(String), failed(String)
    }

    var body: some View {
        Form {
            Section("Anthropic API key") {
                HStack {
                    SecureField(
                        hasStoredKey ? "Stored in the Keychain" : "sk-ant-…",
                        text: $apiKey
                    )
                    Button("Save") { save() }
                        .disabled(apiKey.nilIfEmpty == nil)
                    if hasStoredKey {
                        Button("Remove", role: .destructive) { remove() }
                    }
                }
                Text("Kept in the Keychain — never in preferences or a file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                TextField("Model", text: $settings.model)
                Text("Default \(AppSettings.defaultModel). Drafting uses structured outputs, so any current model that supports them will work.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Check it works") {
                HStack {
                    Button(testState == .running ? "Testing…" : "Test") {
                        Task { await runTest() }
                    }
                    .disabled(testState == .running || !hasStoredKey)
                    if testState == .running { ProgressView().controlSize(.small) }
                }
                switch testState {
                case .idle:
                    Text("Sends one small request to the Claude API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running:
                    EmptyView()
                case .passed(let detail):
                    Label(detail, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let detail):
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        do {
            try Keychain.write(apiKey, account: Keychain.Account.anthropicAPIKey)
            apiKey = ""
            hasStoredKey = true
            testState = .idle
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func remove() {
        try? Keychain.delete(account: Keychain.Account.anthropicAPIKey)
        hasStoredKey = false
        testState = .idle
    }

    private func runTest() async {
        testState = .running
        guard let key = Keychain.read(account: Keychain.Account.anthropicAPIKey) else {
            testState = .failed("No key stored.")
            return
        }
        do {
            let model = try await AnthropicClient(apiKey: key, model: settings.model).ping()
            testState = .passed("Reached the API as \(model).")
        } catch {
            testState = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

// MARK: - Domains

private struct DomainsSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var newDomain = ""
    @State private var newEnv = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Captures on these hosts raise a toast. Subdomains are included.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.domainRules.watchedDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        TextField(
                            "env tag",
                            text: Binding(
                                get: { settings.domainRules.environmentMap[domain] ?? "" },
                                set: { newValue in
                                    var rules = settings.domainRules
                                    if let tag = newValue.nilIfEmpty {
                                        rules.environmentMap[domain] = tag
                                    } else {
                                        rules.environmentMap.removeValue(forKey: domain)
                                    }
                                    settings.domainRules = rules
                                }
                            )
                        )
                        .frame(width: 110)
                        .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            remove(domain)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 180)

            HStack {
                TextField("app.example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                TextField("env tag", text: $newEnv)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("Add") { add() }
                    .disabled(DomainRules.normalize(newDomain) == nil)
            }
        }
        .padding(16)
    }

    private func add() {
        // Normalised on the way in, so a pasted URL becomes a host.
        guard let domain = DomainRules.normalize(newDomain) else { return }
        var rules = settings.domainRules
        if !rules.watchedDomains.contains(domain) { rules.watchedDomains.append(domain) }
        if let tag = newEnv.nilIfEmpty { rules.environmentMap[domain] = tag }
        settings.domainRules = rules
        newDomain = ""
        newEnv = ""
    }

    private func remove(_ domain: String) {
        var rules = settings.domainRules
        rules.watchedDomains.removeAll { $0 == domain }
        rules.environmentMap.removeValue(forKey: domain)
        settings.domainRules = rules
    }
}

// MARK: - Boards

private struct BoardsSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var selectedID: UUID?
    @State private var showingSetup = false

    private var selected: Board? {
        selectedID.flatMap { id in settings.boards.first { $0.id == id } }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(settings.boards, selection: $selectedID) { board in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(board.name.nilIfEmpty ?? board.site.nilIfEmpty ?? "New board")
                        Text(board.mode == .restAPI ? "REST API" : "Prefilled URL")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(board.id)
                }
                Divider()
                HStack(spacing: 6) {
                    // Setup rather than a blank board: the ids a board needs aren't
                    // things anyone has to hand, and the wizard reads them from Jira.
                    Button { showingSetup = true } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selectedID {
                            settings.removeBoard(id: id)
                            selectedID = settings.boards.first?.id
                        }
                    } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 150, maxWidth: 210)

            if let selected {
                BoardEditor(board: selected, settings: settings)
            } else {
                VStack {
                    Spacer()
                    Text("Add a board to file tickets.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedID = selectedID ?? settings.boards.first?.id }
        .sheet(isPresented: $showingSetup) {
            BoardSetupWizard(
                settings: settings,
                onFinish: { selectedID = $0 },
                onManualSetup: { board in
                    settings.upsert(board: board)
                    selectedID = board.id
                }
            )
        }
    }
}

private struct BoardEditor: View {
    let board: Board
    @Bindable var settings: AppSettings

    @State private var token = ""
    @State private var hasStoredToken = false

    private func binding<T>(_ keyPath: WritableKeyPath<Board, T>) -> Binding<T> {
        Binding(
            get: { board[keyPath: keyPath] },
            set: { newValue in
                var copy = board
                copy[keyPath: keyPath] = newValue
                settings.upsert(board: copy)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name))
                Picker("Mode", selection: binding(\.mode)) {
                    ForEach(Board.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Jira") {
                TextField("Site", text: binding(\.site), prompt: Text("your-site"))
                Text("The {site} in https://{site}.atlassian.net")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Project ID", text: binding(\.projectID), prompt: Text("10001"))
                TextField("Issue type ID", text: binding(\.issueTypeID), prompt: Text("10004"))
                TextField(
                    "Default labels",
                    text: Binding(
                        get: { board.defaultLabels.joined(separator: ", ") },
                        set: { newValue in
                            var copy = board
                            copy.defaultLabels = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            settings.upsert(board: copy)
                        }
                    ),
                    prompt: Text("triage, from-snag")
                )
            }

            Section("Drafting") {
                TextField(
                    "Product context",
                    text: binding(\.productContext),
                    prompt: Text("What this product is, and the parts a bug can be in"),
                    axis: .vertical
                )
                .lineLimit(4...12)
                Text("Goes at the top of the prompt, above the rules Snag always sends. Leave it empty to draft without any product description.")
                    .font(.caption2).foregroundStyle(.secondary)

                TextField(
                    "Areas",
                    text: Binding(
                        get: { board.areas.joined(separator: ", ") },
                        set: { newValue in
                            var copy = board
                            copy.areas = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            settings.upsert(board: copy)
                        }
                    ),
                    prompt: Text("checkout, search, admin")
                )
                Text("The areas a bug can be classified into, in the order they're offered. Comma separated. Leave it empty and Claude picks its own word for where the bug is.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if board.mode == .restAPI {
                Section("API token") {
                    TextField("Account email", text: binding(\.accountEmail), prompt: Text("you@example.com"))
                    HStack {
                        SecureField(
                            hasStoredToken ? "Stored in the Keychain" : "Atlassian API token",
                            text: $token
                        )
                        Button("Save") { saveToken() }
                            .disabled(token.nilIfEmpty == nil)
                    }
                    Text("Create one at id.atlassian.com › Security › API tokens.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let problem = board.configurationProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshTokenState() }
        .onChange(of: board.id) { _, _ in
            token = ""
            refreshTokenState()
        }
    }

    private func refreshTokenState() {
        hasStoredToken = Keychain.has(account: Keychain.Account.jiraToken(boardID: board.id))
    }

    private func saveToken() {
        try? Keychain.write(token, account: Keychain.Account.jiraToken(boardID: board.id))
        token = ""
        refreshTokenState()
    }
}
