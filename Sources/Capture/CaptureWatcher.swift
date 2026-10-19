import CoreServices
import Foundation

/// Watches the screen-capture folder and reports new captures.
///
/// One `DispatchSource` on one directory, rather than a Spotlight query: it fires in
/// milliseconds, needs no indexing, and covers recordings too (which don't carry the
/// `kMDItemIsScreenCapture` flag that a metadata query would key on).
///
/// Three guards stop false positives, which matter because a false positive interrupts
/// the user with a toast:
///  - **Age** -- files older than `maxAge` at detection time are ignored, so a folder
///    being re-indexed or a batch of files arriving can't replay old captures.
///  - **Settle** -- a file is only reported once its size stops changing, so we never
///    hand a half-written PNG to the downstream image read.
///  - **Corroboration** -- in a dedicated captures folder anything new is a capture; in
///    a shared folder like the Desktop a screenshot must also carry Spotlight's
///    screen-capture flag. That flag is locale-independent, unlike the filename, which
///    is localized ("Bildschirmfoto…") and so can't be matched on.
final class CaptureWatcher {
    struct Capture {
        let url: URL
        let mediaType: SnagRecord.MediaType
        let detectedAt: Date
    }

    /// Delivered on the main queue.
    var onCapture: ((Capture) -> Void)?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    private static let videoExtensions: Set<String> = ["mov", "mp4"]
    private let maxAge: TimeInterval = 30
    private let settleInterval: TimeInterval = 0.15
    /// A screenshot is written in one go, so it settles almost at once. A recording is
    /// still growing while the user records, so it gets a far longer budget -- which is
    /// only affordable because confirmation runs off the scan queue.
    private let imageSettleBudget: TimeInterval = 3
    private let videoSettleBudget: TimeInterval = 300

    private let queue = DispatchQueue(label: "dev.snag.Snag.capture-watcher")
    /// Settling blocks its thread, and a recording can block it for minutes. Doing that
    /// on `queue` would make a screenshot taken mid-recording go undetected, so each
    /// candidate is confirmed concurrently and `queue` stays free to keep scanning.
    private let confirmQueue = DispatchQueue(
        label: "dev.snag.Snag.capture-confirm",
        attributes: .concurrent
    )
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var watched: ScreenshotLocation.Resolved?
    private var seen = Set<String>()
    private var locationPoll: DispatchSourceTimer?

    var watchedFolder: URL? { watched?.url }

    func start() {
        queue.async { [weak self] in
            self?.repoint()
            self?.startLocationPolling()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.locationPoll?.cancel()
            self?.locationPoll = nil
            self?.teardownSource()
        }
    }

    // MARK: - Watching

    /// The screenshot location is a user default that can change while we're running,
    /// and there's no reliable cross-process notification for it, so re-resolve on a
    /// slow timer and move the watch if it moved.
    private func startLocationPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if ScreenshotLocation.resolve() != self.watched { self.repoint() }
        }
        timer.resume()
        locationPoll = timer
    }

    private func repoint() {
        teardownSource()

        let resolved = ScreenshotLocation.resolve()
        watched = resolved

        let fd = open(resolved.url.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.capture.error("cannot watch \(resolved.url.path, privacy: .public) errno=\(errno, privacy: .public)")
            return
        }
        descriptor = fd

        // Seed with what's already there so existing files never fire. The age guard
        // would catch most of them anyway; this makes it certain.
        seen = Set(currentFilenames())

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.source?.data ?? []
            // The folder itself went away or moved -- re-resolve rather than keep a
            // descriptor pointing at nothing.
            if data.contains(.delete) || data.contains(.rename) {
                self.repoint()
            } else {
                self.scan()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 { close(fd) }
            self?.descriptor = -1
        }
        self.source = source
        source.resume()

        // Logged here rather than by the caller: the folder is resolved on this queue,
        // so anything reading `watchedFolder` right after `start()` is racing it.
        Log.capture.notice("watching \(resolved.url.path, privacy: .public) (dedicated=\(resolved.isDedicated, privacy: .public), ignoring \(self.seen.count, privacy: .public) existing files)")
    }

    private func teardownSource() {
        source?.cancel()
        source = nil
    }

    private func currentFilenames() -> [String] {
        guard let url = watched?.url,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return [] }
        return names
    }

    // MARK: - Detection

    private func scan() {
        guard let watched else { return }
        let names = currentFilenames()
        Log.capture.debug("scan: \(names.count, privacy: .public) entries, \(self.seen.count, privacy: .public) already seen")

        for name in names where !seen.contains(name) {
            // macOS writes a capture to a hidden ".Screenshot …" file and renames it
            // into place, so the dotfile is a transient that is about to disappear.
            // Treating it as a candidate spawned a settle poll against a vanishing
            // file and logged a false "never stopped changing" on every screenshot --
            // noise that would hide a real one. Not added to `seen`: the check is one
            // string comparison, and the name is gone by the next scan anyway.
            if Self.isTransient(filename: name) { continue }

            // Mark seen before deciding, so a file we reject isn't re-examined on
            // every subsequent directory event.
            seen.insert(name)

            guard let mediaType = Self.mediaType(forExtension: (name as NSString).pathExtension) else { continue }
            let url = watched.url.appendingPathComponent(name)
            guard isRecent(url) else {
                Log.capture.debug("skipped \(name, privacy: .public): older than \(self.maxAge, privacy: .public)s")
                continue
            }

            Log.capture.notice("candidate \(name, privacy: .public) (\(mediaType.rawValue, privacy: .public))")
            let requiresFlag = !watched.isDedicated
            confirmQueue.async { [weak self] in
                self?.confirm(url: url, mediaType: mediaType, requiresScreenCaptureFlag: requiresFlag)
            }
        }

        // Keep `seen` from growing without bound across a long-running session, while
        // still covering everything currently on disk.
        if seen.count > 4000 { seen = Set(currentFilenames()) }
    }

    /// Hidden files are never finished captures: they're the in-progress write, or a
    /// `.DS_Store`-style artefact.
    static func isTransient(filename: String) -> Bool {
        filename.hasPrefix(".")
    }

    static func mediaType(forExtension ext: String) -> SnagRecord.MediaType? {
        let ext = ext.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    private func isRecent(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate
        else { return false }
        return Date().timeIntervalSince(modified) <= maxAge
    }

    /// Runs off the scan queue: waits for the file to stop growing, checks Spotlight's
    /// flag if the folder is a shared one, then reports the capture.
    private func confirm(url: URL, mediaType: SnagRecord.MediaType, requiresScreenCaptureFlag: Bool) {
        let budget = mediaType == .video ? videoSettleBudget : imageSettleBudget
        guard settle(url, budget: budget) else {
            Log.capture.notice("skipped \(url.lastPathComponent, privacy: .public): never stopped changing")
            return
        }
        // Spotlight may not have indexed a just-written file yet, so allow a few
        // retries rather than rejecting a genuine screenshot on a timing race.
        if requiresScreenCaptureFlag, !awaitScreenCaptureFlag(url) {
            Log.capture.notice("skipped \(url.lastPathComponent, privacy: .public): shared folder and no screen-capture flag")
            return
        }
        Log.capture.notice("detected \(url.lastPathComponent, privacy: .public)")

        let capture = Capture(url: url, mediaType: mediaType, detectedAt: Date())
        DispatchQueue.main.async { [weak self] in self?.onCapture?(capture) }
    }

    /// Returns true once the file's size has held steady across two samples.
    private func settle(_ url: URL, budget: TimeInterval) -> Bool {
        var lastSize: Int64 = -1
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            guard let size = fileSize(url) else { return false }
            if size == lastSize, size > 0 { return true }
            lastSize = size
            Thread.sleep(forTimeInterval: settleInterval)
        }
        return false
    }

    private func awaitScreenCaptureFlag(_ url: URL, attempts: Int = 6) -> Bool {
        for attempt in 0..<attempts {
            if isScreenCapture(url) { return true }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: settleInterval) }
        }
        return false
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// Spotlight's own "this is a screen capture" flag. Verified present on screenshots
    /// taken by macOS; absent on screen recordings, which is why it only gates images.
    private func isScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return false }
        let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString)
        return (value as? NSNumber)?.boolValue ?? false
    }
}
