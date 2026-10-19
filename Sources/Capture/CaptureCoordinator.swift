import AppKit
import Foundation
import Observation

/// Turns a file appearing on disk into a `RecentCapture` with page context attached,
/// and decides whether it deserves a toast.
///
/// Context is gathered at detection time rather than on demand: a second or two later
/// the user may have switched tabs, and the URL that matters is the one that was on
/// screen when they hit the shortcut.
@Observable
@MainActor
final class CaptureCoordinator {
    /// How many captures the menu bar offers. The brief asks for 5; a few more are kept
    /// so the hotkey still has something to open after a couple of dismissals.
    static let recentDisplayLimit = 5
    private static let recentRetentionLimit = 20

    private(set) var recents: [RecentCapture] = []
    /// Surfaced so Settings can explain a missing URL instead of leaving it blank.
    private(set) var lastBrowserFailure: BrowserContextReader.Failure?

    /// Raised when a capture on a watched domain arrives and toasts are enabled.
    var onToastRequested: ((RecentCapture) -> Void)?

    private let watcher = CaptureWatcher()
    private let browserReader = BrowserContextReader()
    private let sentinel = ShutterSentinel()
    private let library: CaptureLibrary
    private let settings: AppSettings
    private let store: JSONFile<[RecentCapture]>

    init(settings: AppSettings, library: CaptureLibrary = CaptureLibrary()) {
        self.settings = settings
        self.library = library
        self.store = JSONFile(url: library.root.appendingPathComponent("recents.json"))
        self.recents = store.load(fallback: [])
    }

    var watchedFolder: URL? { watcher.watchedFolder }

    /// Capture files this list still owns, for the orphan reaper.
    var referencedCaptureFilenames: Set<String> { Set(recents.map(\.captureFilename)) }

    var displayedRecents: [RecentCapture] {
        Array(recents.prefix(Self.recentDisplayLimit))
    }

    var mostRecent: RecentCapture? { recents.first }

    func start() {
        try? library.prepare()
        watcher.onCapture = { [weak self] capture in
            self?.handle(capture)
        }
        // Read the page as the capture starts, not when its file lands seconds later.
        sentinel.onShutter = { [weak self] in
            self?.armPageContext()
        }
        watcher.start()
        sentinel.start()
    }

    func stop() {
        watcher.stop()
        sentinel.stop()
    }

    func url(forCaptureNamed name: String) -> URL { library.url(forCaptureNamed: name) }

    // MARK: - Detection

    /// Import first, enrich second.
    ///
    /// The ordering is deliberate and was learned the hard way: reading the browser can
    /// block (an unanswered Automation dialog did exactly that in testing), and the
    /// capture is the part that would be lost forever. So the file is copied into the
    /// library and listed immediately; the URL is attached a moment later if it can be
    /// had at all.
    private func handle(_ capture: CaptureWatcher.Capture) {
        guard let filename = try? library.importCapture(from: capture.url) else {
            Log.capture.error("couldn't import \(capture.url.lastPathComponent, privacy: .public) into the library")
            return
        }

        var context = CaptureContext.unknown(at: capture.detectedAt)
        context.screenResolution = Self.mainScreenResolution()

        let recent = RecentCapture(
            captureFilename: filename,
            originalPath: capture.url.path,
            mediaType: capture.mediaType,
            context: context,
            detectedAt: capture.detectedAt
        )
        recents.insert(recent, at: 0)
        trimRecents()
        persist()

        // The page was usually read when the capture started -- see `armPageContext`.
        // Using that reading is both more accurate (it predates the seconds the user
        // spent moving on) and faster: no Apple Event stands between the file landing
        // and the toast.
        if let armed = takeArmedReading(landedAt: capture.detectedAt) {
            attach(armed.reading, to: recent.id, capturedAt: armed.takenAt)
            return
        }

        // Nothing armed -- the floating thumbnail is off (so the file is only 0.3s old
        // and reading now is accurate), or the capture came from something that doesn't
        // use the capture agent. Apple Events are synchronous and can stall, so the
        // read happens off the main actor and the toast decision waits on its (bounded)
        // outcome. `Task` inherits this type's actor, so `attach` is back on main; only
        // the blocking call is detached, and it captures the reader rather than `self`.
        let reader = browserReader
        Task { [weak self] in
            let reading = await Task.detached(priority: .userInitiated) {
                reader.readFrontmost()
            }.value
            self?.attach(reading, to: recent.id)
        }
    }

    /// `capturedAt` is passed when the reading came from the shutter, so the ticket is
    /// dated when the screenshot was taken rather than when macOS got round to writing
    /// it -- up to six seconds apart.
    private func attach(
        _ reading: BrowserContextReader.Reading,
        to captureID: UUID,
        capturedAt: Date? = nil
    ) {
        lastBrowserFailure = reading.failure
        guard let index = recents.firstIndex(where: { $0.id == captureID }) else { return }

        if let capturedAt { recents[index].context.capturedAt = capturedAt }
        recents[index].context.browserBundleID = reading.bundleID
        recents[index].context.browserName = reading.appName
        recents[index].context.url = reading.page?.url
        recents[index].context.pageTitle = reading.page?.title
        recents[index].context.env = settings.domainRules.environment(
            forHost: recents[index].context.host
        )
        persist()

        let capture = recents[index]
        if let failure = reading.failure {
            Log.context.notice("no page context: \(String(describing: failure), privacy: .public)")
        } else {
            Log.context.notice("page \(capture.displayHost, privacy: .public) env=\(capture.context.env ?? "-", privacy: .public)")
        }

        // No toast off a watched domain -- the capture still shows under Recent
        // captures, which is the brief's rule exactly.
        if settings.toastEnabled, settings.domainRules.isWatched(host: capture.context.host) {
            onToastRequested?(capture)
        }
    }

    /// Reads the browser on demand, for the Report panel's "Use current tab". Never
    /// prompts, like every other read on this path.
    func readCurrentPage() async -> BrowserContextReader.Reading {
        let reader = browserReader
        let reading = await Task.detached(priority: .userInitiated) {
            reader.readFrontmost()
        }.value
        lastBrowserFailure = reading.failure
        return reading
    }

    // MARK: - Shutter arming

    /// A page reading taken as a capture began, waiting for its file to land.
    private struct ArmedReading {
        var reading: BrowserContextReader.Reading
        var takenAt: Date
    }

    /// Generous, because the sentinel announces the capture *overlay*, not the shutter:
    /// a selection drag or a left-open screenshot bar can put a minute between the two.
    /// Being generous is cheap -- a parked reading only ever loses to a fresher one, and
    /// it is still the page the user was on when they started capturing.
    private static let armedValidity: TimeInterval = 120
    /// Deep enough for a burst of shots, shallow enough that nothing lingers.
    private static let armedQueueLimit = 4
    /// Oldest first.
    private var armedQueue: [ArmedReading] = []

    /// Reads the page as a capture starts, and parks the reading for the file that is
    /// about to arrive.
    ///
    /// Only one read happens per capture interaction, deliberately. Re-reading while the
    /// overlay is up would keep the reading fresh for someone who opens the screenshot
    /// bar, switches tab and *then* shoots -- but it would also overwrite a correct
    /// reading with a wrong one for everyone who shoots and immediately moves on, which
    /// is the far commoner case and the one this exists to fix. The rarer case is
    /// covered by the page being editable in the Report panel.
    private func armPageContext() {
        let reader = browserReader
        // Timestamped from before the read: the read itself can take up to two seconds,
        // and the shutter is the moment being dated.
        let startedAt = Date()
        Task { [weak self] in
            let reading = await Task.detached(priority: .userInitiated) {
                reader.readFrontmost()
            }.value
            guard let self else { return }
            // A reading that learned nothing is not parked: arming can fail because the
            // browser was busy or consent was never granted, and a read at detection
            // time can only do better than a failed one.
            guard reading.page != nil else {
                Log.context.notice("nothing to arm: \(String(describing: reading.failure), privacy: .public)")
                return
            }
            self.armedQueue.append(ArmedReading(reading: reading, takenAt: startedAt))
            if self.armedQueue.count > Self.armedQueueLimit { self.armedQueue.removeFirst() }
            Log.context.notice("armed \(reading.page?.url ?? "-", privacy: .public) for the capture in flight")
        }
    }

    /// The reading that belongs to a file that just landed.
    ///
    /// The queue is consumed only while something is waiting behind it, so two captures
    /// in quick succession each get their own reading, while several shots taken in one
    /// screenshot session share the single reading taken when it opened.
    private func takeArmedReading(landedAt: Date) -> ArmedReading? {
        armedQueue.removeAll { landedAt.timeIntervalSince($0.takenAt) > Self.armedValidity }
        guard let next = armedQueue.first else { return nil }
        if armedQueue.count > 1 { armedQueue.removeFirst() }
        return next
    }

    // MARK: - Permissions

    /// Supported browsers running right now, with the consent state of each. Probing
    /// never prompts, so this is safe to call just to render Settings.
    func browserPermissions() -> [(bundleID: String, name: String, permission: BrowserContextReader.Permission)] {
        BrowserContextReader.runningSupportedBrowsers().map { browser in
            (browser.bundleID, browser.name, BrowserContextReader.permission(forBundleID: browser.bundleID))
        }
    }

    /// Raises the consent dialog for one browser, on purpose, from Settings. Blocks on
    /// the user's answer, so it runs off the main actor.
    func requestBrowserPermission(forBundleID bundleID: String) async -> BrowserContextReader.Permission {
        let result = await Task.detached(priority: .userInitiated) {
            BrowserContextReader.requestPermission(forBundleID: bundleID)
        }.value
        if result == .permitted { lastBrowserFailure = nil }
        // Logged because the alternative is reading tccd's own output to find out how
        // a grant went, which is not a reasonable thing to ask of anyone.
        Log.context.notice("""
            grant requested for \(bundleID, privacy: .public): \
            \(String(describing: result), privacy: .public)
            """)
        return result
    }

    private static func mainScreenResolution() -> String? {
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        let points = "\(Int(frame.width))×\(Int(frame.height))"
        guard scale > 1 else { return points }
        return "\(points) @\(Int(scale))x"
    }

    // MARK: - Promotion and retention

    /// Marks a capture as reported so it isn't offered again and its file is kept.
    func markReported(captureID: UUID, recordID: UUID) {
        guard let index = recents.firstIndex(where: { $0.id == captureID }) else { return }
        recents[index].promotedRecordID = recordID
        persist()
    }

    /// Returns a capture to Recent captures after it's been detached from a report.
    /// Also what keeps its file alive: the orphan reaper only spares files something
    /// still refers to.
    func unmarkReported(captureID: UUID) {
        guard let index = recents.firstIndex(where: { $0.id == captureID }) else { return }
        recents[index].promotedRecordID = nil
        persist()
    }

    /// Dismissing creates nothing; the capture simply stops being offered.
    func dismiss(captureID: UUID) {
        guard let index = recents.firstIndex(where: { $0.id == captureID }) else { return }
        let removed = recents.remove(at: index)
        if !removed.isReported { library.deleteCapture(named: removed.captureFilename) }
        persist()
    }

    /// Captures that aged out without being reported own nothing, so their copied file
    /// goes with them -- otherwise the library grows forever behind the user's back.
    private func trimRecents() {
        guard recents.count > Self.recentRetentionLimit else { return }
        let dropped = recents[Self.recentRetentionLimit...]
        for capture in dropped where !capture.isReported {
            library.deleteCapture(named: capture.captureFilename)
        }
        recents = Array(recents.prefix(Self.recentRetentionLimit))
    }

    private func persist() {
        do {
            try store.save(recents)
        } catch {
            Log.store.error("couldn't save recent captures: \(String(describing: error), privacy: .public)")
        }
    }
}
