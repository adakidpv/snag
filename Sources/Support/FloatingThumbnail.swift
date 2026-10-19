import Foundation

/// macOS's post-capture floating thumbnail, as a setting Snag can read and change.
///
/// Same checkbox as ⌘⇧5 › Options › Show Floating Thumbnail, and it is the single
/// biggest cost in Snag's capture path: while the thumbnail is on screen the capture is
/// held in memory by `screencaptureui` and no file exists for Snag to see. Measured
/// shortcut-to-file on a machine with three displays: 5.6-6.0s with the thumbnail on,
/// 0.3s with it off.
///
/// Snag's toast replaces what the thumbnail is for -- it carries Report and Dismiss, and
/// the capture is already saved by the time it appears -- so turning the thumbnail off
/// is usually the right trade. What's lost is clicking the thumbnail to mark up, and
/// dragging it straight into another app.
///
/// Written with CFPreferences against another application's domain, which is what
/// `defaults write` does and which is available because Snag is unsandboxed. The
/// screenshot agent is launched afresh for each capture and reads the value then, so a
/// change takes effect on the very next screenshot with no logout or restart.
enum FloatingThumbnail {
    private static let domain = "com.apple.screencapture" as CFString
    private static let key = "show-thumbnail" as CFString

    /// True when macOS will show the thumbnail. Absent means true -- that's the macOS
    /// default, and the key is absent on a machine where nobody has touched it.
    static var isEnabled: Bool {
        guard let value = CFPreferencesCopyValue(
            key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) else { return true }
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// Turning it back on removes the key rather than writing `true`, so Snag leaves
    /// nothing behind in someone else's preference domain once it's been undone.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        CFPreferencesSetValue(
            key,
            enabled ? nil : kCFBooleanFalse,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synchronized = CFPreferencesSynchronize(
            domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        Log.capture.notice("""
            floating thumbnail \(enabled ? "restored" : "switched off", privacy: .public) \
            (synchronized=\(synchronized, privacy: .public))
            """)
        return synchronized
    }
}
