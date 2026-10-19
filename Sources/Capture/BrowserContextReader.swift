import AppKit
import Foundation

/// Reads the frontmost browser's active tab via Apple Events.
///
/// Scripts address browsers by bundle id (`tell application id "com.google.Chrome"`)
/// rather than by name, so a localized or renamed application still resolves.
///
/// Every failure is non-fatal and named: a denied Automation prompt, a browser with no
/// windows, or a frontmost app that isn't a browser all mean "no URL", never "no
/// capture". The brief is explicit that the hotkey has to keep working when Automation
/// is refused, so the reason is surfaced rather than swallowed.
final class BrowserContextReader {
    struct Page: Equatable {
        var url: String
        var title: String?
    }

    struct Reading {
        var bundleID: String?
        var appName: String?
        var page: Page?
        var failure: Failure?
    }

    enum Failure: Error, Equatable {
        case frontmostAppIsNotABrowser(String?)
        case permissionDenied
        /// Consent has never been granted or refused. Distinct from `permissionDenied`
        /// because it's fixable with one click, and because Snag won't raise the dialog
        /// itself mid-capture.
        case permissionNotRequested
        case timedOut
        case noOpenWindow
        case browserNotRunning
        case scriptFailed(code: Int, message: String?)

        /// True for both "refused" and "never asked" -- the UI treats them the same
        /// way, as something the user can act on.
        var isPermissionProblem: Bool {
            self == .permissionDenied || self == .permissionNotRequested
        }

        var userDescription: String {
            switch self {
            case .frontmostAppIsNotABrowser(let name):
                return "\(name ?? "The frontmost app") isn't a supported browser, so there's no page URL."
            case .permissionDenied:
                return "Snag isn't allowed to read the browser. Grant it in System Settings › Privacy & Security › Automation."
            case .permissionNotRequested:
                return "Snag hasn't been granted access to the browser yet. Use “Grant browser access” in Settings."
            case .timedOut:
                return "The browser didn't answer in time, so there's no page URL."
            case .noOpenWindow:
                return "The browser has no open window."
            case .browserNotRunning:
                return "The browser isn't running."
            case .scriptFailed(let code, let message):
                return message.map { "Couldn't read the browser (\($0))." } ?? "Couldn't read the browser (error \(code))."
            }
        }
    }

    /// Chromium-family browsers share the `active tab of front window` vocabulary.
    /// Only a couple of these are typically installed; the rest are here because the
    /// vocabulary is identical and they cost nothing to support.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Safari exposes `front document` instead.
    static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    static func isSupportedBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumBundleIDs.contains(bundleID) || safariBundleIDs.contains(bundleID)
    }

    /// AppleScript is synchronous and slow enough to matter, so it never runs on main.
    private let queue = DispatchQueue(label: "dev.snag.Snag.applescript")

    /// Whether Snag may send Apple Events to a given app, established *without*
    /// triggering a consent dialog.
    enum Permission {
        case permitted
        case denied
        /// Consent has never been asked for. Asking raises a modal dialog, and the
        /// script call blocks until it's answered -- so asking is done deliberately
        /// from Settings, never on the path that handles a capture.
        case notDetermined
        case appNotRunning
    }

    /// Asks the Apple Event manager about consent without prompting.
    ///
    /// This exists because of a failure found in testing: with Chrome frontmost and
    /// consent not yet granted, macOS raised a TCC dialog and `executeAndReturnError`
    /// blocked until it was answered. Checking first means an unanswered or refused
    /// prompt costs a URL, never a capture.
    static func permission(forBundleID bundleID: String) -> Permission {
        var target = AEAddressDesc()
        var identifier = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, &identifier, identifier.count, &target) == noErr else {
            return .notDetermined
        }
        defer { AEDisposeDesc(&target) }

        // A wildcard class and ID ask "may I automate this app at all?".
        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false // never prompt
        )

        switch status {
        case noErr: return .permitted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .appNotRunning
        default: return .notDetermined
        }
    }

    /// Blocking, but bounded. Call from a background queue. Returns whatever could be
    /// learned; never prompts unless asked to, and never waits longer than `timeout`.
    func readFrontmost(timeout: TimeInterval = 2.0, allowPrompt: Bool = false) -> Reading {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName

        guard Self.isSupportedBrowser(bundleID: bundleID), let bundleID else {
            return Reading(
                bundleID: bundleID,
                appName: appName,
                page: nil,
                failure: .frontmostAppIsNotABrowser(appName)
            )
        }

        switch Self.permission(forBundleID: bundleID) {
        case .denied:
            return Reading(bundleID: bundleID, appName: appName, page: nil, failure: .permissionDenied)
        case .appNotRunning:
            return Reading(bundleID: bundleID, appName: appName, page: nil, failure: .browserNotRunning)
        case .notDetermined where !allowPrompt:
            return Reading(bundleID: bundleID, appName: appName, page: nil, failure: .permissionNotRequested)
        case .notDetermined, .permitted:
            break
        }

        let script = Self.safariBundleIDs.contains(bundleID)
            ? Self.safariScript(bundleID: bundleID)
            : Self.chromiumScript(bundleID: bundleID)

        switch runBounded(script, timeout: timeout) {
        case .success(let page):
            return Reading(bundleID: bundleID, appName: appName, page: page, failure: nil)
        case .failure(let failure):
            return Reading(bundleID: bundleID, appName: appName, page: nil, failure: failure)
        }
    }

    /// Runs the script on a worker and gives up after `timeout`.
    ///
    /// A wedged browser or a consent dialog can block an Apple Event indefinitely. The
    /// worker is left to finish on its own -- it unblocks once the dialog is answered --
    /// while the caller moves on with no URL.
    private func runBounded(_ script: String, timeout: TimeInterval) -> Result<Page, Failure> {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: Result<Page, Failure>?

        queue.async {
            let result = Self.run(script)
            lock.lock()
            if outcome == nil { outcome = result }
            lock.unlock()
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        if outcome == nil { outcome = .failure(.timedOut) }
        let settled = outcome!
        lock.unlock()
        return settled
    }

    /// Raises the Automation consent dialog for one named app, whatever is frontmost.
    ///
    /// This must not go through `readFrontmost`: clicking a Grant button in Snag's own
    /// Settings window makes *Snag* the frontmost app, so a frontmost-based check can
    /// never see a browser and always fails. Targeting the browser by bundle id side-
    /// steps that entirely.
    ///
    /// Blocking and unbounded by design — it waits for the user to answer the dialog.
    /// The target app must be running, or macOS has nothing to prompt about.
    static func requestPermission(forBundleID bundleID: String) -> Permission {
        var target = AEAddressDesc()
        var identifier = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, &identifier, identifier.count, &target) == noErr else {
            return .notDetermined
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            true // prompt, because the user asked for it
        )

        switch status {
        case noErr: return .permitted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .appNotRunning
        default: return .notDetermined
        }
    }

    /// Supported browsers that are running right now, so Settings can offer each one
    /// rather than guessing at a single "the" browser.
    static func runningSupportedBrowsers() -> [(bundleID: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  isSupportedBrowser(bundleID: bundleID),
                  seen.insert(bundleID).inserted
            else { return nil }
            return (bundleID, app.localizedName ?? bundleID)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Scripts

    private static func chromiumScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then error "no window" number -1728
            set theTab to active tab of front window
            return {URL of theTab, title of theTab}
        end tell
        """
    }

    private static func safariScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            if (count of documents) is 0 then error "no window" number -1728
            set theDoc to front document
            return {URL of theDoc, name of theDoc}
        end tell
        """
    }

    private static func run(_ source: String) -> Result<Page, Failure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed(code: -1, message: "script wouldn't compile"))
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            switch code {
            // Automation consent refused, or not yet granted and the prompt declined.
            case -1743, -10004: return .failure(.permissionDenied)
            case -600, -609: return .failure(.browserNotRunning)
            case -1728: return .failure(.noOpenWindow)
            default: return .failure(.scriptFailed(code: code, message: message))
            }
        }

        // The script returns a two-item list; AppleScript indexes from 1.
        guard descriptor.numberOfItems >= 1,
              let urlString = descriptor.atIndex(1)?.stringValue,
              !urlString.isEmpty
        else {
            return .failure(.noOpenWindow)
        }

        let title = descriptor.numberOfItems >= 2
            ? descriptor.atIndex(2)?.stringValue?.nilIfEmpty
            : nil
        return .success(Page(url: urlString, title: title))
    }
}
