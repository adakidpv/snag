import AppKit
import Foundation

/// Reports when a screen capture *starts*, which is several seconds before its file
/// exists.
///
/// macOS holds a capture in memory while its floating thumbnail is on screen and only
/// writes the file once the thumbnail expires. Measured on a machine with the thumbnail
/// enabled: 5.6-6.0s from shortcut to file, against 0.3s with it switched off. Reading
/// the browser when the file lands therefore reports whatever tab the user moved to
/// during those six seconds -- and if they moved off a watched domain, no toast fires
/// at all. So the browser is read here instead, at the start of the capture.
///
/// `com.apple.screencaptureui` is the agent that draws the selection overlay and the
/// thumbnail. It is launched per capture and quits a few seconds after writing the
/// file, so its presence marks a capture in flight. Three measured details shape this:
///
///  - It appears in `runningApplications` 0.26-0.40s after the shortcut, which is close
///    enough to the shutter to be the same page.
///  - It never becomes frontmost: the app being captured stays frontmost throughout.
///    That's what makes the ordinary frontmost-browser read correct at this instant.
///  - It is `LSUIElement`, and `NSWorkspace.didLaunchApplicationNotification` does
///    *not* fire for it. Only the `runningApplications` array changes. KVO on that
///    array does fire (verified), so that -- not the notification, and not a poll --
///    is what's observed here.
///
/// Nothing is reported when the floating thumbnail is switched off: the agent isn't
/// launched at all, and it isn't needed, because the file lands 0.3s after the shutter.
@MainActor
final class ShutterSentinel {
    static let captureAgentBundleID = "com.apple.screencaptureui"

    /// Raised once per capture interaction, as it begins.
    var onShutter: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private var agentWasRunning = false

    func start() {
        guard observation == nil else { return }
        agentWasRunning = Self.isCaptureAgentRunning()
        // The change dictionary carries only the inserted apps on current macOS, but
        // that isn't documented, so the authoritative array is re-read on every fire
        // and the transition is tracked here.
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    private func evaluate() {
        let running = Self.isCaptureAgentRunning()
        defer { agentWasRunning = running }
        guard running, !agentWasRunning else { return }
        Log.capture.notice("capture started (screencaptureui up); reading page context now")
        onShutter?()
    }

    private static func isCaptureAgentRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == captureAgentBundleID
        }
    }
}
