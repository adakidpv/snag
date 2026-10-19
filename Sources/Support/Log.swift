import Foundation
import os

/// Logging for a background agent with no window to print into.
///
/// `os.Logger` rather than `NSLog`: NSLog redacts interpolated values as `<private>` in
/// the unified log, which makes "which capture was skipped, and why" unanswerable after
/// the fact. Paths and reasons here are explicitly `privacy: .public` -- this is a local
/// developer tool, and the whole point of these lines is to be readable with
/// `log show --predicate 'subsystem == "dev.snag.Snag"'`.
enum Log {
    private static let subsystem = "dev.snag.Snag"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let context = Logger(subsystem: subsystem, category: "context")
    static let drafting = Logger(subsystem: subsystem, category: "drafting")
    static let jira = Logger(subsystem: subsystem, category: "jira")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let app = Logger(subsystem: subsystem, category: "app")
}
