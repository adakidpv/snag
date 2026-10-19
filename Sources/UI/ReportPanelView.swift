import SwiftUI

/// The Report panel: capture, detected context, the one question, and -- once drafted --
/// every ticket field, editable.
struct ReportPanelView: View {
    @Bindable var session: ReportSession
    /// For the captures that can still be added: it's observable, so the picker keeps
    /// up with screenshots taken while the panel is open.
    let coordinator: CaptureCoordinator
    /// Non-nil when the browser couldn't be read, so the panel can say why the URL is
    /// missing rather than just showing a blank.
    let contextProblem: String?
    var boards: [Board] = []

    @FocusState private var noteFocused: Bool

    /// Drafting is the earlier step, so its blocker is the more useful one to show.
    private var blockedReason: String? {
        if session.draft == nil, let reason = session.draftBlockedReason { return reason }
        return session.filingBlockedReason
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    header
                    if showsFilmstrip { filmstrip }
                    noteField
                    if let notice = session.notice { noticeBanner(notice) }
                    if let message = session.errorMessage { errorBanner(message) }
                    if session.draft != nil { draftFields }
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 440)
        // The whole point of the hotkey is typing immediately, so the caret starts in
        // the note field rather than nowhere. Asynchronously, because the page field
        // above it takes first responder as the window comes up and would otherwise
        // win -- which put the caret in the URL, with the URL selected.
        .onAppear {
            DispatchQueue.main.async { noteFocused = session.draft == nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CaptureThumbnail(
                url: session.captureURL,
                mediaType: session.capture.mediaType,
                width: 124,
                height: 78
            )

            VStack(alignment: .leading, spacing: 4) {
                // Editable, and styled to read as text until you click it. Detection is
                // right almost always; this is the repair for when it isn't, and it's
                // cheaper than filing a ticket that points at the wrong page.
                HStack(spacing: 4) {
                    TextField(
                        "No page detected — paste the URL",
                        text: $session.pageURLField
                    )
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1)

                    Button {
                        Task { await session.useCurrentTab() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the browser's current tab instead")
                }

                if let title = session.context.pageTitle {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let env = session.context.env {
                        Label(env.uppercased(), systemImage: "cube")
                    }
                    if session.capture.mediaType == .video {
                        Label("Recording", systemImage: "video")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                if session.isPageEdited {
                    Text("The ticket will use this page.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let contextProblem {
                    Text(contextProblem)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Captures

    /// Hidden entirely for the ordinary single-screenshot report with nothing else to
    /// add, so that path looks exactly as it did before any of this existed.
    private var showsFilmstrip: Bool {
        session.captures.count > 1 || !addableCaptures.isEmpty
    }

    /// Unreported captures that aren't already on this report, newest first.
    private var addableCaptures: [RecentCapture] {
        coordinator.recents.filter { !$0.isReported && !session.contains(captureID: $0.id) }
    }

    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(session.captures.count > 1
                     ? "\(session.captures.count) screenshots"
                     : "Screenshot")
                    .font(.subheadline.weight(.semibold))
                if session.captures.count > 1 {
                    Text("primary first")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                addMenu
            }

            if session.captures.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(session.captures.enumerated()), id: \.element.id) { index, capture in
                            attachedThumbnail(capture, index: index)
                        }
                    }
                }
            }
        }
    }

    private func attachedThumbnail(_ capture: RecentCapture, index: Int) -> some View {
        CaptureThumbnail(
            url: coordinator.url(forCaptureNamed: capture.captureFilename),
            mediaType: capture.mediaType,
            width: 84,
            height: 53
        )
        .overlay(alignment: .topLeading) {
            Text("\(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(3)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                session.remove(captureID: capture.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Take it off this report — it goes back to Recent captures")
        }
        .contextMenu {
            Button("Make primary") { session.makePrimary(captureID: capture.id) }
                .disabled(index == 0)
            Button("Remove") { session.remove(captureID: capture.id) }
        }
    }

    @ViewBuilder
    private var addMenu: some View {
        if session.canAddCapture, !addableCaptures.isEmpty {
            Menu {
                ForEach(addableCaptures) { capture in
                    Button {
                        session.add(capture)
                    } label: {
                        Text("\(capture.displayHost) — \(capture.detectedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Put another recent capture on this ticket")
        } else if !session.canAddCapture {
            Text("Four is the limit")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Note

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What went wrong?").font(.subheadline.weight(.semibold))

            TextEditor(text: $session.note)
                .font(.body)
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                .focused($noteFocused)

            Text("One sentence is enough — the draft fills in the rest.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// For a change made to this report from somewhere else -- the Inbox merging its
    /// snag into another ticket while the panel sat open. Not an error, so it's stated
    /// rather than coloured as a failure, but it has to be said: the panel is writing
    /// somewhere else now.
    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                session.clearNotice()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                session.clearError()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Draft

    @ViewBuilder
    private var draftFields: some View {
        if let draft = Binding($session.draft) {
            VStack(alignment: .leading, spacing: 13) {
                Divider()

                field("Title") {
                    TextField("", text: draft.title)
                        .textFieldStyle(.roundedBorder)
                    characterCount(draft.wrappedValue.title.count)
                }

                field("Summary") {
                    TextEditor(text: draft.summary)
                        .font(.body)
                        .frame(minHeight: 48)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                }

                field("Steps to reproduce") {
                    // One step per line: far easier to reorder and edit than a list of
                    // individual fields, and it maps cleanly to the array.
                    TextEditor(text: linesBinding(draft.stepsToReproduce))
                        .font(.body)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    Text("One step per line.").font(.caption2).foregroundStyle(.tertiary)
                }

                HStack(alignment: .top, spacing: 12) {
                    field("Expected") {
                        TextField("", text: draft.expected, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }
                    field("Actual") {
                        TextField("", text: draft.actual, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }
                }

                HStack(spacing: 12) {
                    field("Area") {
                        Picker("", selection: draft.area) {
                            // Nothing configured and nothing drafted: the picker still
                            // needs an entry matching the selection, or it shows blank
                            // with no way back.
                            if draft.wrappedValue.area.nilIfEmpty == nil { Text("—").tag("") }
                            ForEach(areaOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                    }
                    field("Severity") {
                        Picker("", selection: draft.severity) {
                            ForEach(DraftedTicket.Severity.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                field("Labels") {
                    TextField("comma separated", text: labelsBinding(draft.labels))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    /// The board's configured taxonomy, plus whatever the draft came back with -- an
    /// area outside the list is kept rather than silently swapped for a configured one.
    private var areaOptions: [String] {
        var options = session.board?.normalizedAreas ?? []
        if let area = session.draft?.area.nilIfEmpty, !options.contains(area) {
            options.append(area)
        }
        return options
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func characterCount(_ count: Int) -> some View {
        Text("\(count)/\(DraftedTicket.titleLimit)")
            .font(.caption2)
            .foregroundStyle(
                count > DraftedTicket.titleLimit
                    ? AnyShapeStyle(.orange)
                    : AnyShapeStyle(.tertiary)
            )
    }

    /// `[String]` <-> newline-separated text. Blank lines are dropped on the way back
    /// so pressing return twice doesn't create an empty step.
    private func linesBinding(_ source: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue.joined(separator: "\n") },
            set: { source.wrappedValue = $0.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } }
        )
    }

    private func labelsBinding(_ source: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue.joined(separator: ", ") },
            set: { source.wrappedValue = $0.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if boards.count > 1 {
                Picker("Board", selection: $session.selectedBoardID) {
                    ForEach(boards) { board in
                        Text(board.name.nilIfEmpty ?? board.site).tag(Optional(board.id))
                    }
                }
                .frame(maxWidth: 220)
            }

            if let reason = blockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if session.isDrafting || session.isFiling {
                ProgressView().controlSize(.small)
                Text(session.isDrafting ? "Drafting…" : "Filing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let key = session.filedKey {
                Label(key, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }

            // The escape hatch for a prefilled description that doesn't survive into
            // Jira's editor.
            Button("Copy text") { session.copyTicketTextToClipboard() }
                .help("Copy the whole ticket body, ready to paste into Jira")

            Button(session.draft == nil ? "Draft" : "Redraft") {
                Task { await session.draftTicket() }
            }
            .disabled(!session.canDraft)
            .keyboardShortcut(.return, modifiers: .command)

            Button(session.filingLabel) {
                Task { await session.file() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canFile)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
