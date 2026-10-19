import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`, which is the whole of launch-at-login on
/// macOS 13+. Registration throws when the app is not in a location the system will
/// launch from (notably while running out of a build directory), so callers get the
/// error rather than a toggle that silently lies about its state.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The system refuses registration from locations it won't launch from -- notably
    /// a build directory. The error is wrapped with that hint rather than guessed at
    /// up front, so the advice only appears when registration has actually failed.
    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw Failure.registration(underlying: error, wasEnabling: enabled)
        }
    }

    enum Failure: LocalizedError {
        case registration(underlying: Error, wasEnabling: Bool)

        var errorDescription: String? {
            guard case .registration(let underlying, let wasEnabling) = self else { return nil }
            let verb = wasEnabling ? "register" : "unregister"
            return "Couldn't \(verb) Snag as a login item: \(underlying.localizedDescription)"
                + (wasEnabling ? " macOS won't launch an app from a build folder — run Snag from /Applications." : "")
        }
    }

    /// `.notFound` is reported for an app that simply has no login-item registration
    /// yet -- it does **not** mean the app is in the wrong place. This was verified:
    /// a copy running from `/Applications` still reports `.notFound` until it has been
    /// registered once. Describing it as "move Snag to /Applications" told the user to
    /// fix something that wasn't broken, so both unregistered states now read as "Off"
    /// and any genuine problem is surfaced by the registration attempt itself.
    /// Non-nil only when the toggle alone doesn't tell the whole story. "On" and "Off"
    /// are already visible in the switch, so repeating them underneath is noise;
    /// "needs approval" is a state the switch cannot express and the user must act on.
    static var statusNote: String? {
        switch SMAppService.mainApp.status {
        case .enabled, .notRegistered, .notFound: return nil
        case .requiresApproval: return statusDescription
        @unknown default: return statusDescription
        }
    }

    /// The full state, for logging and diagnostics.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "On"
        case .notRegistered, .notFound: return "Off"
        case .requiresApproval: return "Needs approval in System Settings › General › Login Items"
        @unknown default: return "Unknown"
        }
    }
}
