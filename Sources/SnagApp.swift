import KeyboardShortcuts
import SwiftUI

@main
struct SnagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `coordinator` is non-optional on purpose. It used to be an optional set in
        // applicationDidFinishLaunching, and SwiftUI evaluated this closure once while
        // it was still nil and never again -- so the dropdown was an empty panel that
        // toggled open and shut. Nothing here may depend on launch ordering.
        MenuBarExtra("Snag", systemImage: "viewfinder.rectangular") {
            MenuBarContent(
                coordinator: appDelegate.coordinator,
                onReport: { appDelegate.openReport(for: $0) },
                onOpenInbox: { appDelegate.openInbox() },
                onOpenSettings: { appDelegate.openSettings() }
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The app is an `LSUIElement` agent, so there is no main menu and no Dock icon.
/// AppKit still owns activation and window lifetime, which the toast (which must *not*
/// activate) and the Report panel (which must) need to differ on.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    private let library = CaptureLibrary()
    private(set) lazy var store = SnagStore(library: library)
    private(set) lazy var coordinator = CaptureCoordinator(settings: settings, library: library)

    private let windows = WindowManager()
    private let toast = ToastController()
    /// Keyed by *every* capture on a session, not just the one it was opened for, so
    /// a session is reachable from any of its captures. Kept so closing the panel
    /// doesn't discard a typed note or a draft that cost an API call.
    private var sessions: [UUID: ReportSession] = [:]
    /// The session the Report window is currently showing.
    private var shownSessionID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Lets the Inbox resolve a snag's board without threading settings through
        // every view initialiser.
        BoardRegistry.shared.configure { [settings] in settings.boards }

        // Both the recents list and the record store own capture files, so orphans can
        // only be judged once both have loaded.
        library.reapOrphans(
            referenced: coordinator.referencedCaptureFilenames
                .union(store.referencedCaptureFilenames)
        )
        coordinator.onToastRequested = { [weak self] capture in
            self?.showToast(for: capture)
        }
        coordinator.start()

        toast.onReport = { [weak self] capture in
            self?.openReport(for: capture)
        }
        toast.onAdd = { [weak self] capture in
            self?.addToOpenReport(capture)
        }
        toast.onDismiss = { [weak self] capture in
            // Dismissing creates nothing -- it just stops the capture being offered.
            self?.coordinator.dismiss(captureID: capture.id)
        }

        // The hotkey is the path that has to work when everything else fails: no toast,
        // no Automation permission, nothing in the menu.
        KeyboardShortcuts.onKeyUp(for: .openReport) { [weak self] in
            self?.openReportForMostRecent()
        }

        logBrowserPermissions()
        Log.app.notice("launch at login: \(LaunchAtLogin.statusDescription, privacy: .public) (bundle: \(Bundle.main.bundlePath, privacy: .public))")

        // Development aid: an agent app has no scriptable UI, and the global hotkey
        // can't be pressed from a script without Accessibility consent, so this is how
        // each window gets exercised from the command line.
        //   SNAG_OPEN_AT_LAUNCH=report|inbox|settings Snag.app/Contents/MacOS/Snag
        if let target = ProcessInfo.processInfo.environment["SNAG_OPEN_AT_LAUNCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                switch target {
                case "report": self?.openReportForMostRecent()
                case "inbox": self?.openInbox()
                case "settings": self?.openSettings()
                default: Log.app.error("unknown SNAG_OPEN_AT_LAUNCH=\(target, privacy: .public)")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    // MARK: - Report

    func showToast(for capture: RecentCapture) {
        Log.app.notice("toast for \(capture.displayHost, privacy: .public)")
        let mode: ToastController.Mode = openReportSession
            .map { .addToOpenReport(attachedCount: $0.captures.count) } ?? .newReport
        toast.show(
            for: capture,
            thumbnailURL: coordinator.url(forCaptureNamed: capture.captureFilename),
            mode: mode
        )
    }

    /// The report a new capture can join: the one on screen, as long as it hasn't been
    /// filed and has room. Keyed to the window being open rather than a timer, so the
    /// rule is one the user can see -- while the report is open, new screenshots can
    /// join it.
    private var openReportSession: ReportSession? {
        guard windows.isOpen(.report),
              let id = shownSessionID,
              let session = sessions[id],
              session.filedKey == nil,
              session.canAddCapture
        else { return nil }
        return session
    }

    /// Adds a capture to the open report, and makes sure every path back to that
    /// session can find it by this capture's id.
    private func addToOpenReport(_ capture: RecentCapture) {
        guard let session = openReportSession else {
            // The report closed between the toast appearing and Add being clicked.
            openReport(for: capture)
            return
        }
        session.add(capture)
        sessions[capture.id] = session
        windows.bringForward(.report)
    }

    func openReportForMostRecent() {
        guard let capture = coordinator.mostRecent else {
            Log.app.notice("hotkey pressed with no capture to report")
            presentNothingToReport()
            return
        }
        // Pressing the hotkey again with a report already open means "this one too",
        // not "throw that away and start again" -- the window is reused, so starting
        // again would replace the panel being typed into.
        if let session = openReportSession, !session.contains(captureID: capture.id) {
            addToOpenReport(capture)
            return
        }
        openReport(for: capture)
    }

    func openReport(for capture: RecentCapture) {
        toast.hide()
        Log.app.notice("report panel for \(capture.captureFilename, privacy: .public)")

        let session = reportSession(for: capture, coordinator: coordinator)
        shownSessionID = session.capture.id
        // The only window that rebuilds its content: this call may be for a different
        // capture than the one already on screen.
        windows.show(
            .report,
            title: "Report a bug",
            size: CGSize(width: 560, height: 560),
            replacingContent: true
        ) { [settings] in
            ReportPanelView(
                session: session,
                coordinator: coordinator,
                contextProblem: capture.context.url == nil
                    ? coordinator.lastBrowserFailure?.userDescription
                    : nil,
                boards: settings.boards
            )
        }
    }

    /// One session per capture, reused so a note or a paid-for draft survives the panel
    /// being closed and reopened.
    private func reportSession(
        for capture: RecentCapture,
        coordinator: CaptureCoordinator
    ) -> ReportSession {
        if let existing = sessions[capture.id] { return existing }

        let existingRecord = capture.promotedRecordID.flatMap { store.record(id: $0) }
            ?? store.records.first { $0.captureFilenames.contains(capture.captureFilename) }

        let session = ReportSession(
            captures: captures(for: capture, in: existingRecord),
            store: store,
            settings: settings,
            coordinator: coordinator,
            existingRecord: existingRecord
        )
        for member in session.captures { sessions[member.id] = session }
        return session
    }

    /// Every capture a reopened record owns, in its stored order.
    private func captures(
        for capture: RecentCapture,
        in record: SnagRecord?
    ) -> [RecentCapture] {
        guard let record, record.hasMultipleCaptures else { return [capture] }
        return captures(of: record, preferring: capture)
    }

    /// Every capture a record owns, in its stored order.
    ///
    /// A record can name captures that have aged out of the recents list, so those are
    /// rebuilt from the record itself -- the files are still in the library, which is
    /// the point of copying them in. `preferring` stands in for its own filename, so a
    /// capture the caller already holds keeps its identity, and with it the keys the
    /// session cache is kept under.
    private func captures(
        of record: SnagRecord,
        preferring known: RecentCapture? = nil
    ) -> [RecentCapture] {
        record.captureFilenames.map { filename in
            if let known, known.captureFilename == filename { return known }
            if let recent = coordinator.recents.first(where: { $0.captureFilename == filename }) {
                return recent
            }
            return RecentCapture(
                captureFilename: filename,
                originalPath: library.url(forCaptureNamed: filename).path,
                mediaType: record.mediaType,
                context: record.context,
                detectedAt: record.createdAt,
                promotedRecordID: record.id
            )
        }
    }

    /// The hotkey firing with nothing to report should say so, not do nothing at all.
    private func presentNothingToReport() {
        let alert = NSAlert()
        alert.messageText = "No recent capture"
        alert.informativeText = "Take a screenshot and press the shortcut again."
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Other windows

    func openInbox() {
        windows.show(.inbox, title: "Snag Inbox", size: CGSize(width: 860, height: 540)) { [store] in
            InboxView(
                store: store,
                onReopen: { [weak self] record in
                    self?.openReport(forExisting: record)
                },
                onMerged: { [weak self] result in
                    self?.recordsMerged(result)
                },
                onDeleted: { [weak self] id in
                    self?.recordDeleted(id)
                }
            )
        }
    }

    /// Captures changed hands in the Inbox, so what still points at the records that
    /// went away has to be put right.
    ///
    /// Three things do. A recents entry names the record it was promoted to, and that
    /// record may no longer exist. A cached report session holds its own capture list:
    /// reopening the panel from one of those would write the pre-merge list back over
    /// the record and strand the captures the merge just moved, so the affected sessions
    /// are dropped and rebuilt from the record next time. And the session the Report
    /// panel is showing *now* can't just be dropped -- someone is typing into it -- so
    /// it follows the merge onto the ticket that survived instead.
    private func recordsMerged(_ result: SnagStore.MergeResult) {
        for filename in result.movedCaptureFilenames {
            guard let capture = coordinator.recents.first(where: { $0.captureFilename == filename })
            else { continue }
            coordinator.markReported(captureID: capture.id, recordID: result.record.id)
        }

        let onTicket = Set(result.record.captureFilenames)
        // Held before the cache is pruned, which is where it would otherwise be lost.
        let onScreen = windows.isOpen(.report) ? shownSession : nil
        for (captureID, session) in sessions where isStale(session, ticket: onTicket) {
            sessions[captureID] = nil
        }
        if let onScreen, isStale(onScreen, ticket: onTicket) {
            follow(onScreen, into: result.record)
        }
        Log.app.notice("""
            merged into \(result.record.captureFilenames.count, privacy: .public) capture(s); \
            \(result.movedCaptureFilenames.count, privacy: .public) capture(s) changed hands
            """)
    }

    /// Re-points the open Report panel at the merged ticket, and makes every path back
    /// to that session find it under the captures it now carries.
    ///
    /// Not brought forward: the user is in the Inbox, and the panel says what happened
    /// when they return to it.
    private func follow(_ session: ReportSession, into record: SnagRecord) {
        session.followMerge(into: record, captures: captures(of: record))
        for member in session.captures { sessions[member.id] = session }
        // The primary may be a different capture now, and this is keyed to the primary.
        shownSessionID = session.capture.id
    }

    /// A snag was deleted in the Inbox, which took its capture files with it.
    ///
    /// Everything still pointing at it has to let go. A Report panel open on that snag
    /// has nothing left to draft from and nothing to save a note to -- and were it left
    /// able to file, the Jira issue would be created for real with no record to hold its
    /// key. So the window closes, the cached sessions go, and the captures stop being
    /// offered under Recent captures, since the files behind them are gone.
    private func recordDeleted(_ recordID: UUID) {
        if windows.isOpen(.report), shownSession?.recordID == recordID {
            windows.close(.report)
            shownSessionID = nil
        }
        for (captureID, session) in sessions where session.recordID == recordID {
            sessions[captureID] = nil
        }
        for capture in coordinator.recents where capture.promotedRecordID == recordID {
            coordinator.dismiss(captureID: capture.id)
        }
        Log.app.notice("snag deleted: its panel, session and captures let go")
    }

    /// The session the Report window is showing, if it still has one.
    private var shownSession: ReportSession? {
        shownSessionID.flatMap { sessions[$0] }
    }

    /// A session is stale once its record has gone, or once any of its captures sits
    /// on a ticket built by a merge it knows nothing about.
    private func isStale(_ session: ReportSession, ticket: Set<String>) -> Bool {
        if let recordID = session.recordID, store.record(id: recordID) == nil { return true }
        return session.captures.contains { ticket.contains($0.captureFilename) }
    }

    /// Re-opens the Report panel for an already-reported snag, carrying its note back
    /// into the field.
    func openReport(forExisting record: SnagRecord) {
        guard let capture = recentCapture(matching: record) else {
            // The capture is still in the library even when it has aged out of the
            // recents list, so rebuild just enough to show the panel.
            let synthetic = RecentCapture(
                id: record.id,
                captureFilename: record.captureFilename,
                originalPath: library.url(forCaptureNamed: record.captureFilename).path,
                mediaType: record.mediaType,
                context: record.context,
                detectedAt: record.createdAt,
                promotedRecordID: record.id
            )
            openReport(for: synthetic)
            return
        }
        openReport(for: capture)
    }

    private func recentCapture(matching record: SnagRecord) -> RecentCapture? {
        coordinator.recents.first { $0.captureFilename == record.captureFilename }
    }

    func openSettings() {
        // Resizable, and tall enough for the General tab: at 430pt the browser-access
        // section was cut off by the window edge with no way to scroll to it.
        windows.show(
            .settings,
            title: "Snag Settings",
            size: CGSize(width: 680, height: 620)
        ) { [settings] in
            SettingsView(settings: settings, coordinator: coordinator)
        }
    }

    // MARK: - Diagnostics

    /// Reports Automation consent per running browser at launch. Probing never
    /// prompts, so this is safe to do unattended -- and it makes "why is there no URL
    /// on my ticket?" answerable from the log.
    private func logBrowserPermissions() {
        let supported = BrowserContextReader.chromiumBundleIDs
            .union(BrowserContextReader.safariBundleIDs)
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, supported.contains(bundleID) else { continue }
            let state = BrowserContextReader.permission(forBundleID: bundleID)
            Log.context.notice("automation for \(bundleID, privacy: .public): \(String(describing: state), privacy: .public)")
        }
    }
}
