import SwiftUI

/// Dropdown shown from the status bar item: the last few captures, then the app's
/// three actions. `MenuBarExtra(.window)` renders real SwiftUI rather than menu items,
/// which is what lets the capture rows carry thumbnails.
struct MenuBarContent: View {
    let coordinator: CaptureCoordinator
    var onReport: (RecentCapture) -> Void = { _ in }
    var onOpenInbox: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if coordinator.displayedRecents.isEmpty {
                Text("No captures yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(coordinator.displayedRecents) { capture in
                        CaptureRow(capture: capture, url: coordinator.url(forCaptureNamed: capture.captureFilename)) {
                            onReport(capture)
                        }
                    }
                }
                .padding(.bottom, 6)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton("Open Inbox", action: onOpenInbox)
                MenuRowButton("Settings…", action: onOpenSettings)
                MenuRowButton("Quit Snag") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 290)
    }

    private var header: some View {
        HStack {
            Text("Recent captures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            // A denied Automation prompt is the one failure that silently degrades the
            // whole app, so it gets said out loud rather than left as a blank URL.
            if coordinator.lastBrowserFailure?.isPermissionProblem == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Snag can't read the browser. Grant Automation in System Settings › Privacy & Security.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct CaptureRow: View {
    let capture: RecentCapture
    let url: URL
    let action: () -> Void
    @State private var isHovering = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                CaptureThumbnail(url: url, mediaType: capture.mediaType)

                VStack(alignment: .leading, spacing: 1) {
                    Text(capture.displayHost)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(Self.timeFormatter.string(from: capture.detectedAt))
                        if let env = capture.context.env {
                            Text(env.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                        if capture.isReported {
                            Text("Reported")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
    }
}

private struct MenuRowButton: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.accentColor.opacity(0.85) : .clear)
                )
                .foregroundStyle(isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
    }
}
