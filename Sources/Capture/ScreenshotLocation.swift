import Foundation

/// Finds the folder macOS saves screen captures into.
///
/// This is not `~/Desktop` as often assumed -- it's whatever `com.apple.screencapture`
/// `location` says, which on a current macOS is typically `~/Pictures/Screenshots`.
/// Reading the
/// real default matters twice over: captures are found at all, and a dedicated folder
/// lets detection be far less fussy than it must be on a shared folder like the Desktop.
enum ScreenshotLocation {
    /// Folders where files other than captures routinely appear, so a new image there
    /// needs corroboration before Snag treats it as a screenshot.
    private static var sharedFolders: Set<URL> {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var urls: Set<URL> = [home]
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory,
                          .documentDirectory, .picturesDirectory, .moviesDirectory] {
            if let url = try? fm.url(for: directory, in: .userDomainMask,
                                     appropriateFor: nil, create: false) {
                urls.insert(url.resolvingSymlinksInPath())
            }
        }
        return urls
    }

    struct Resolved: Equatable {
        var url: URL
        /// True when the folder exists only for captures, so anything new in it is one.
        var isDedicated: Bool
    }

    static func resolve() -> Resolved {
        let fm = FileManager.default
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        // `defaults` stores this as a path string, which may be relative to home, may
        // use a tilde, and may point somewhere that no longer exists.
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var url = fallback
        if let configured, !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            let candidate = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : fm.homeDirectoryForCurrentUser.appendingPathComponent(expanded, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                url = candidate
            }
        }

        let resolvedPath = url.resolvingSymlinksInPath()
        return Resolved(url: resolvedPath, isDedicated: !sharedFolders.contains(resolvedPath))
    }
}
