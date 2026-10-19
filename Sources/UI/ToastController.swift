import AppKit
import SwiftUI

/// The "Report this?" toast.
///
/// This is the one piece of UI that must *not* steal focus: the user has just taken a
/// screenshot and is still working in the browser. So it's an `NSPanel` with
/// `.nonactivatingPanel`, shown without activating the app -- clicking Report is what
/// finally brings Snag forward.
@MainActor
final class ToastController {
    /// What the toast offers. A capture taken while a report is already open almost
    /// always belongs *on* that report -- one screenshot often can't show a bug -- so
    /// it offers to join rather than starting a second ticket. Starting a new one is
    /// still right there, and the single-capture toast is untouched.
    enum Mode: Equatable {
        case newReport
        /// `attachedCount` is what the open report holds already, so the toast can say
        /// what Add would produce.
        case addToOpenReport(attachedCount: Int)
    }

    /// The brief's 8 seconds.
    private let visibleDuration: TimeInterval = 8
    private let size = CGSize(width: 310, height: 92)
    /// The add toast carries a third button, and squeezing three into 92pt left them
    /// touching.
    private let addModeSize = CGSize(width: 310, height: 116)
    /// Clear of the menu bar and the notification area.
    private let screenInset = CGSize(width: 18, height: 12)

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    var onReport: ((RecentCapture) -> Void)?
    var onDismiss: ((RecentCapture) -> Void)?
    /// Add it to the report that's already open.
    var onAdd: ((RecentCapture) -> Void)?

    func show(for capture: RecentCapture, thumbnailURL: URL, mode: Mode = .newReport) {
        // A newer capture supersedes an older toast rather than stacking.
        hide()

        let size = mode == .newReport ? self.size : addModeSize
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        // Follow the user across spaces and sit above full-screen apps -- a web app
        // under test is the kind of thing people run full screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = ToastView(
            capture: capture,
            thumbnailURL: thumbnailURL,
            mode: mode,
            onAdd: { [weak self] in
                self?.hide()
                self?.onAdd?(capture)
            },
            onReport: { [weak self] in
                self?.hide()
                self?.onReport?(capture)
            },
            onDismiss: { [weak self] in
                self?.hide()
                self?.onDismiss?(capture)
            },
            onHoverChange: { [weak self] isHovering in
                // Don't let the toast vanish from under a cursor on its way to Report.
                if isHovering {
                    self?.cancelAutoDismiss()
                } else {
                    self?.scheduleAutoDismiss(for: capture)
                }
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        let frame = topRightFrame(size: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless() // show without activating

        Log.app.notice("""
            toast shown at \(Int(frame.origin.x), privacy: .public),\
            \(Int(frame.origin.y), privacy: .public) \
            visible=\(panel.isVisible, privacy: .public) \
            appActive=\(NSApp.isActive, privacy: .public)
            """)
        self.panel = panel
        scheduleAutoDismiss(for: capture)
    }

    func hide() {
        cancelAutoDismiss()
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleAutoDismiss(for capture: RecentCapture) {
        cancelAutoDismiss()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.visibleDuration ?? 8) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            // Timing out is not the same as dismissing: the brief says a *dismissed*
            // toast creates nothing, and an ignored one should leave the capture in
            // Recent captures untouched. So this only hides.
            self?.hide()
        }
    }

    private func cancelAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Top-right of whichever screen currently has the mouse, so on a multi-display
    /// setup the toast appears where the user is looking.
    private func topRightFrame(size: CGSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - size.width - screenInset.width,
            y: visible.maxY - size.height - screenInset.height,
            width: size.width,
            height: size.height
        )
    }
}

/// A borderless panel still needs to accept clicks without the app becoming active.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ToastView: View {
    let capture: RecentCapture
    let thumbnailURL: URL
    let mode: ToastController.Mode
    let onAdd: () -> Void
    let onReport: () -> Void
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    private var isAdding: Bool {
        if case .addToOpenReport = mode { return true }
        return false
    }

    private var title: String {
        switch mode {
        case .newReport:
            return "Report this?"
        case .addToOpenReport(let attached):
            return "Add to the open report? (\(attached + 1))"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            CaptureThumbnail(url: thumbnailURL, mediaType: capture.mediaType, width: 58, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Text(capture.displayHost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let env = capture.context.env {
                        Text(env.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(spacing: 5) {
                if isAdding {
                    Button("Add", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("New report", action: onReport)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Report", action: onReport)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .onHover(perform: onHoverChange)
    }
}
