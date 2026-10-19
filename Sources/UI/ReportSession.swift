import AppKit
import Foundation
import Observation

/// State for one trip through the Report panel.
///
/// Held by the app rather than the view so closing the panel and reopening it (or
/// pressing the hotkey again) doesn't discard a typed note or a draft that cost an API
/// call. The record is created as soon as drafting starts, so a draft is never lost to
/// a crash or a closed window either.
@Observable
@MainActor
final class ReportSession {
    /// Primary first. One capture usually; several when one screenshot couldn't show
    /// the bug -- the state before it, the error, the console.
    private(set) var captures: [RecentCapture]

    var note: String
    var draft: DraftedTicket?
    var selectedBoardID: UUID?
    /// Mutable, because the detected page can be wrong and the user is the one who
    /// knows. It's right the overwhelming majority of the time -- Snag reads the page
    /// as the capture starts, not when its file lands -- but a capture taken with no
    /// browser frontmost, or with the screenshot bar left open across a tab change,
    /// needs correcting by hand rather than shipping a wrong URL on the ticket.
    var context: CaptureContext

    private(set) var isDrafting = false
    private(set) var errorMessage: String?
    /// Something outside the panel changed what this report is attached to -- the Inbox
    /// folding its snag into another ticket, say. Said in the window being typed into,
    /// because that's where the surprise would otherwise land.
    private(set) var notice: String?
    private(set) var recordID: UUID?

    private let store: SnagStore
    private let settings: AppSettings
    private let coordinator: CaptureCoordinator

    init(
        captures: [RecentCapture],
        store: SnagStore,
        settings: AppSettings,
        coordinator: CaptureCoordinator,
        existingRecord: SnagRecord? = nil
    ) {
        precondition(!captures.isEmpty, "a report always has at least the capture it was opened for")
        self.captures = captures
        self.store = store
        self.settings = settings
        self.coordinator = coordinator
        // The parameter, not the `capture` computed property: reading `self` here
        // precedes the rest of the stored properties being initialised.
        self.context = existingRecord?.context ?? captures[0].context
        self.note = existingRecord?.note ?? ""
        self.draft = existingRecord?.draft
        self.recordID = existingRecord?.id
        self.selectedBoardID = existingRecord?.boardID ?? settings.preferredBoard?.id
    }

    // MARK: - The captures

    /// The capture the panel leads with, the model is pointed at first, and a manual
    /// paste into Jira gets.
    var capture: RecentCapture { captures[0] }
    var captureURLs: [URL] {
        captures.map { coordinator.url(forCaptureNamed: $0.captureFilename) }
    }
    var captureURL: URL { captureURLs[0] }
    /// Recordings are kept and attached, but aren't sent to the model.
    var draftableURLs: [URL] {
        captures
            .filter { $0.mediaType == .image }
            .map { coordinator.url(forCaptureNamed: $0.captureFilename) }
    }

    func contains(captureID: UUID) -> Bool {
        captures.contains { $0.id == captureID }
    }

    /// Adds a capture to this report. Taking another screenshot while a report is open
    /// is the common way more than one ends up on a ticket, so this is reachable from
    /// the toast and the hotkey as well as the panel.
    func add(_ capture: RecentCapture) {
        guard !contains(captureID: capture.id) else { return }
        guard captures.count < Self.captureLimit else { return }
        // Nothing to add it to: claiming the capture for a record that has left the
        // Inbox would take it out of Recent captures and put it nowhere.
        guard !isDetached else { return }
        captures.append(capture)
        // Claimed straight away, so it isn't offered again and the orphan reaper leaves
        // its file alone.
        if let recordID { coordinator.markReported(captureID: capture.id, recordID: recordID) }
        persistNote()
        Log.app.notice("report now has \(self.captures.count, privacy: .public) capture(s)")
    }

    /// Never removes the last one: a report with no capture isn't a report.
    func remove(captureID: UUID) {
        guard captures.count > 1, let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        let removed = captures.remove(at: index)
        // Back to being offered under Recent captures, which also keeps its file from
        // being reaped now that this record no longer refers to it.
        coordinator.unmarkReported(captureID: removed.id)
        persistNote()
    }

    func makePrimary(captureID: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }), index != 0 else { return }
        let moved = captures.remove(at: index)
        captures.insert(moved, at: 0)
        persistNote()
    }

    /// Four is the ceiling the drafting prompt is written for, and past it the images
    /// cost more than they tell the model. One number, shared with the Inbox's merge.
    static let captureLimit = SnagRecord.captureLimit
    var canAddCapture: Bool { captures.count < Self.captureLimit }

    // MARK: - When the Inbox moves the ground

    /// Whether the record this report writes to has left the Inbox.
    ///
    /// It can go while the panel is open: deleted in the Inbox, or merged into another
    /// ticket. `SnagStore.modify` can't write to an id it no longer holds, so from here
    /// on a typed note saves nothing -- and filing would create a real Jira issue with
    /// no record left to put its key on. So this blocks both buttons rather than
    /// letting the panel look like it still works.
    var isDetached: Bool {
        guard let recordID else { return false }
        return store.record(id: recordID) == nil
    }

    private var detachedReason: String? {
        isDetached
            ? "This snag isn't in the Inbox any more — nothing here can be saved or filed."
            : nil
    }

    /// Re-points this report at the ticket an Inbox merge left behind.
    ///
    /// Kinder than closing the window: the captures and the note moved to a ticket that
    /// is still there, and that ticket is the one the user now means. Called whether
    /// this report's own snag is the one that survived (its capture list grew) or one of
    /// the ones that was folded in (its record is gone).
    func followMerge(into record: SnagRecord, captures: [RecentCapture]) {
        let keptOwnTicket = recordID == record.id
        recordID = record.id
        self.captures = captures

        // The merge folded the other snags' notes into the ticket's, and this panel's
        // copy of the note predates that -- so take the ticket's, or the next save from
        // here would write those folded-in notes straight back off it. Anything typed
        // here since the last save can't have reached the ticket, so it's appended
        // rather than dropped: the rule the merge itself applies to the notes it folds
        // in, overlap and all.
        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = record.note.contains(typed)
            ? record.note
            : [record.note.nilIfEmpty, typed.nilIfEmpty].compactMap { $0 }.joined(separator: "\n\n")

        if keptOwnTicket {
            notice = "The snags you merged joined this ticket — it carries "
                + "\(captures.count) captures now, and their notes are on it."
        } else {
            // A different record is the ticket now, so its draft, board and page are the
            // ones that count. Where this report kept its own ticket they're untouched by
            // the merge, and the panel's may hold edits that aren't saved yet, so they
            // stay as they are.
            draft = record.draft
            context = record.context
            selectedBoardID = record.boardID ?? selectedBoardID
            notice = "These snags are one ticket now. This panel has moved to the one you kept"
                + (record.jiraKey.map { ", \($0)" } ?? "")
                + " — its note and draft are what the ticket carries."
        }

        // Saves the appended note, and makes the record and the panel agree on the
        // capture list before anything else can write a stale one back.
        persistNote()
        Log.app.notice("""
            report followed a merge into a ticket carrying \
            \(self.captures.count, privacy: .public) capture(s)
            """)
    }

    func clearNotice() { notice = nil }

    // MARK: - The page

    /// Empty string rather than nil, because that's what a text field binds to.
    var pageURLField: String {
        get { context.url ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // A text field writes its binding back on focus and on commit as well as on
            // every keystroke, so a no-op write must stay a no-op -- otherwise merely
            // clicking into the field counts as editing the page.
            guard trimmed.nilIfEmpty != context.url else { return }
            context.url = trimmed.nilIfEmpty
            // The env tag is derived from the host, so an edited URL has to re-derive
            // it -- otherwise a corrected page keeps the old page's environment.
            context.env = settings.domainRules.environment(forHost: context.host)
            // The old title belonged to the old page.
            context.pageTitle = nil
        }
    }

    /// Whether the page differs from the one detected at capture time. Derived rather
    /// than flagged, so it can't be set by a stray write, and so correcting a typo back
    /// to the detected value reads as untouched again.
    var isPageEdited: Bool { context.url != capture.context.url }

    /// Replaces the page with whatever is in the browser right now.
    func useCurrentTab() async {
        let reading = await coordinator.readCurrentPage()
        guard let page = reading.page else {
            errorMessage = reading.failure?.userDescription
                ?? "Couldn't read the browser's current tab."
            return
        }
        context.url = page.url
        context.pageTitle = page.title
        context.browserBundleID = reading.bundleID
        context.browserName = reading.appName
        context.env = settings.domainRules.environment(forHost: context.host)
        persistNote()
    }

    // MARK: - Availability

    var hasAPIKey: Bool { Keychain.has(account: Keychain.Account.anthropicAPIKey) }

    /// Why Draft is unavailable, or nil when it's ready.
    var draftBlockedReason: String? {
        // First, because it trumps everything else: there is nowhere to put a draft,
        // and after a deletion there isn't a capture file to draft from either.
        if let reason = detachedReason { return reason }
        if draftableURLs.isEmpty {
            return "Drafting from recordings isn't supported yet — file it with a note and attach the recording."
        }
        if !hasAPIKey {
            return "Add an Anthropic API key in Settings to draft."
        }
        return nil
    }

    var canDraft: Bool { draftBlockedReason == nil && !isDrafting }

    var board: Board? {
        selectedBoardID.flatMap { id in settings.boards.first { $0.id == id } }
    }

    // MARK: - Drafting

    func draftTicket() async {
        guard canDraft else { return }
        errorMessage = nil
        isDrafting = true
        defer { isDrafting = false }

        // Save the note first. If the API call fails, the user's words are already on
        // a record rather than only in a window they might close in frustration.
        persistNote()

        guard let apiKey = Keychain.read(account: Keychain.Account.anthropicAPIKey) else {
            errorMessage = AnthropicClient.Failure.missingAPIKey.localizedDescription
            return
        }

        let client = AnthropicClient(apiKey: apiKey, model: settings.model)
        do {
            // The product description and the area taxonomy come from the board being
            // filed to: one machine may report to several teams, each with its own.
            let ticket = try await client.draftTicket(
                captures: draftableURLs,
                note: note,
                context: context,
                productContext: board?.productContext,
                areas: board?.normalizedAreas ?? []
            )
            draft = ticket
            persistDraft()
            Log.drafting.notice("drafted \"\(ticket.title, privacy: .public)\"")
        } catch {
            // The note survives: it's in `note` and already on the record.
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Log.drafting.error("draft failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Persistence

    /// Creates the record on first write and keeps it in step afterwards.
    @discardableResult
    func persistNote() -> UUID {
        if let recordID {
            store.modify(id: recordID) { record in
                record.note = self.note
                record.boardID = self.selectedBoardID
                record.context = self.context
                record.captureFilenames = self.captures.map(\.captureFilename)
            }
            return recordID
        }

        let record = store.promote(
            captures,
            note: note,
            boardID: selectedBoardID,
            context: context
        )
        recordID = record.id
        for capture in captures {
            coordinator.markReported(captureID: capture.id, recordID: record.id)
        }
        return record.id
    }

    func persistDraft() {
        let id = persistNote()
        store.modify(id: id) { $0.draft = self.draft }
    }

    func clearError() { errorMessage = nil }

    // MARK: - Filing

    /// Why filing is unavailable, or nil when it's ready.
    var filingBlockedReason: String? {
        // The one that costs real money to get wrong: filing is a live Jira issue, and
        // a record that isn't there can't hold its key.
        if let reason = detachedReason { return reason }
        guard let board else { return "Add a board in Settings to file tickets." }
        if let problem = board.configurationProblem { return problem }
        if draft == nil && note.nilIfEmpty == nil {
            return "Write a note or draft a ticket first."
        }
        return nil
    }

    var canFile: Bool { filingBlockedReason == nil && !isFiling }

    var filingLabel: String {
        board?.mode == .prefilledURL ? "Open in Jira" : "File in Jira"
    }

    private(set) var isFiling = false
    private(set) var filedKey: String?

    /// Falls back to the note when there's no draft, so a capture can still be filed
    /// without spending an API call.
    private var effectiveTitle: String {
        draft?.title.nilIfEmpty
            ?? note.nilIfEmpty.map { String($0.prefix(DraftedTicket.titleLimit)) }
            ?? "Bug captured with Snag"
    }

    private var effectiveDraft: DraftedTicket {
        if let draft { return draft }
        var fallback = DraftedTicket.empty
        fallback.title = effectiveTitle
        fallback.summary = note
        return fallback
    }

    private var labels: [String] {
        (board?.defaultLabels ?? []) + (draft?.labels ?? [])
    }

    func file() async {
        guard canFile, let board else { return }
        errorMessage = nil
        isFiling = true
        defer { isFiling = false }

        let recordID = persistNote()
        store.modify(id: recordID) { $0.draft = self.draft }

        switch board.mode {
        case .restAPI:
            await fileViaAPI(board: board, recordID: recordID)
        case .prefilledURL:
            fileViaPrefilledURL(board: board, recordID: recordID)
        }
    }

    private func body(for board: Board) -> TicketBody {
        TicketBody.make(
            from: effectiveDraft,
            context: context,
            attachment: board.mode == .restAPI
                ? .automatic(count: captures.count)
                : .manual(count: captures.count)
        )
    }

    private func fileViaAPI(board: Board, recordID: UUID) async {
        guard let token = Keychain.read(account: Keychain.Account.jiraToken(boardID: board.id)) else {
            errorMessage = JiraClient.Failure
                .missingConfiguration("No Jira API token stored for this board")
                .localizedDescription
            return
        }

        let client = JiraClient(site: board.site, accountEmail: board.accountEmail, apiToken: token)
        do {
            let issue = try await client.file(
                title: effectiveTitle,
                body: body(for: board),
                labels: labels,
                projectID: board.projectID,
                issueTypeID: board.issueTypeID,
                attachments: captureURLs
            )
            markFiled(key: issue.key, recordID: recordID, boardID: board.id)
        } catch JiraClient.Failure.attachmentFailed(let key, let reason) {
            // The issue exists. Record it as filed and report only the attachment
            // problem -- treating this as a total failure would have the user file
            // the same bug twice.
            markFiled(key: key, recordID: recordID, boardID: board.id)
            errorMessage = "Filed \(key), but \(captures.count > 1 ? "a capture" : "the screenshot") "
                + "didn't attach: \(reason) The capture is on the clipboard — paste it into the ticket."
            copyCaptureToClipboard()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.jira.error("filing failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The brief's original handoff: open a prefilled create screen, put the image on
    /// the clipboard, and reveal it in Finder so it can be pasted or dragged in.
    private func fileViaPrefilledURL(board: Board, recordID: UUID) {
        let body = body(for: board)
        guard let url = JiraLinkBuilder.url(for: .init(
            site: board.site,
            projectID: board.projectID,
            issueTypeID: board.issueTypeID,
            summary: effectiveTitle,
            description: body.wikiMarkup(),
            labels: labels
        )) else {
            errorMessage = "Couldn't build a Jira URL — check the site in Settings › Boards."
            return
        }

        NSWorkspace.shared.open(url)
        copyCaptureToClipboard()
        // Every capture is revealed, so a report with four of them can be dragged in
        // together rather than hunted down one at a time.
        NSWorkspace.shared.activateFileViewerSelecting(captureURLs)

        // No key to record: the user creates the issue themselves and pastes the key
        // back into the Inbox.
        store.modify(id: recordID) { record in
            record.status = .filed
            record.boardID = board.id
        }
        settings.lastUsedBoardID = board.id
        Log.jira.notice("opened prefilled create screen for \(board.site, privacy: .public)")
    }

    private func markFiled(key: String, recordID: UUID, boardID: UUID) {
        filedKey = key
        let recorded = store.modify(id: recordID) { record in
            record.status = .filed
            record.jiraKey = key
            record.boardID = boardID
        }
        settings.lastUsedBoardID = boardID

        // Belt and braces for a race the blocked button is meant to prevent: the issue
        // is in Jira, and if the record went away between the two there is nothing left
        // to hold the key. Then the key has to reach the user here or nowhere.
        guard !recorded else { return }
        errorMessage = "Filed \(key) in Jira, but this snag had already left the Inbox — "
            + "the key is saved nowhere, so note it down: \(key)."
        Log.jira.error("filed \(key, privacy: .public) with no record left to put it on")
    }

    /// Both the image and the file URLs go on the pasteboard, so a capture can be
    /// pasted into Jira's editor or dropped from Finder.
    ///
    /// Only the primary's image data is written even when several are attached: pasting
    /// a multi-image pasteboard into a text editor is unreliable, and the rest are
    /// reachable as files from the same pasteboard and from the Finder reveal.
    func copyCaptureToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardWriting] = captureURLs.map { $0 as NSURL }
        if capture.mediaType == .image, let image = NSImage(contentsOf: captureURL) {
            items.insert(image, at: 0)
        }
        pasteboard.writeObjects(items)
    }

    /// Settings' fallback for when a prefilled description doesn't survive into Jira's
    /// editor: the whole body as text, ready to paste.
    func copyTicketTextToClipboard() {
        let text = body(for: board ?? Board()).wikiMarkup()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(effectiveTitle)\n\n\(text)", forType: .string)
    }
}
