import AppKit
import SwiftUI

/// Keeps one window per key, reusing it rather than stacking duplicates.
///
/// `MenuBarExtra` can't own these: an `LSUIElement` agent has no window menu and no
/// default window lifetime, so Report, Inbox and Settings are plain `NSWindow`s hosting
/// SwiftUI. Showing one activates the app, which is what lets a text field take focus.
@MainActor
final class WindowManager {
    enum Key: String {
        case report, inbox, settings
    }

    private var windows: [Key: NSWindow] = [:]
    private var retainedDelegates: [Key: WindowDelegate] = [:]

    /// `replacingContent` rebuilds the hosting view of a window that is already open.
    ///
    /// Only the Report panel wants that: each report is a different session, so its
    /// content genuinely changes between calls. Nothing else may rebuild. Replacing the
    /// hosting view destroys the SwiftUI tree inside it, and with it every piece of
    /// `@State` -- which silently wiped a half-finished board setup each time Settings
    /// was reopened from the menu bar. Settings and the Inbox don't need it anyway:
    /// their content is driven by observable objects that update the existing tree.
    func show<Content: View>(
        _ key: Key,
        title: String,
        size: CGSize,
        resizable: Bool = true,
        replacingContent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[key] {
            if replacingContent {
                existing.contentView = NSHostingView(rootView: content())
            }
            bringForward(existing)
            return
        }

        // No .fullSizeContentView: nothing here draws under the titlebar, and it left
        // the window title jammed up against the traffic lights.
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        // Remember where the user put it, per window.
        window.setFrameAutosaveName("Snag.\(key.rawValue)")

        let delegate = WindowDelegate { [weak self] in
            self?.windows[key] = nil
            self?.retainedDelegates[key] = nil
        }
        window.delegate = delegate
        retainedDelegates[key] = delegate
        windows[key] = window

        bringForward(window)
    }

    func close(_ key: Key) {
        windows[key]?.close()
    }

    /// Raises a window that already exists, without rebuilding its content -- which
    /// matters for the Report panel, whose content is a live session someone is typing
    /// into.
    func bringForward(_ key: Key) {
        guard let window = windows[key] else { return }
        bringForward(window)
    }

    func isOpen(_ key: Key) -> Bool {
        windows[key]?.isVisible ?? false
    }

    /// An accessory app has to activate explicitly, or the window appears behind the
    /// browser and the note field never gets the keyboard.
    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
