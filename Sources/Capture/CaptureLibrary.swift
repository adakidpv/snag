import Foundation

/// Owns `~/Library/Application Support/Snag/`.
///
/// Captures are copied in rather than referenced where they landed, so the Inbox
/// survives the user clearing out their screenshots folder -- which is the whole point
/// of having an inbox.
struct CaptureLibrary {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.root = support.appendingPathComponent("Snag", isDirectory: true)
        }
    }

    var capturesDirectory: URL { root.appendingPathComponent("captures", isDirectory: true) }
    var storeFile: URL { root.appendingPathComponent("snags.json", isDirectory: false) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
    }

    func url(forCaptureNamed name: String) -> URL {
        capturesDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Copies a capture in and returns the filename to store on the record. Names are
    /// prefixed with a UUID so two captures made in the same second can't collide.
    @discardableResult
    func importCapture(from source: URL) throws -> String {
        try prepare()
        let name = "\(UUID().uuidString).\(source.pathExtension.lowercased())"
        let destination = url(forCaptureNamed: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    func deleteCapture(named name: String) {
        try? FileManager.default.removeItem(at: url(forCaptureNamed: name))
    }

    /// Deletes capture files nothing refers to any more.
    ///
    /// Two things own capture files -- the recent-captures list and the record store --
    /// so this takes the union of both and is called once, after both have loaded.
    /// The age floor protects a file that was just copied in but whose owning entry
    /// hasn't been written yet.
    @discardableResult
    func reapOrphans(referenced: Set<String>, olderThan age: TimeInterval = 60 * 5) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: capturesDirectory.path) else {
            return 0
        }

        var reaped = 0
        for name in names where !referenced.contains(name) {
            let fileURL = url(forCaptureNamed: name)
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) > age
            else { continue }
            try? FileManager.default.removeItem(at: fileURL)
            reaped += 1
        }
        if reaped > 0 { Log.store.notice("reaped \(reaped, privacy: .public) orphaned capture file(s)") }
        return reaped
    }
}
