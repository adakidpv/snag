import Foundation

/// Atomic Codable persistence for a single file.
///
/// The Inbox is the one piece of state in this app that would genuinely hurt to lose,
/// so writes go to a sibling temp file and are swapped in: a crash mid-write leaves the
/// previous good file rather than a truncated one.
struct JSONFile<Value: Codable> {
    let url: URL

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns `fallback` when the file is absent, and also when it's unreadable --
    /// a corrupt file is moved aside rather than crashing the app on every launch.
    func load(fallback: Value) -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            return try Self.decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            Log.store.error("\(url.lastPathComponent, privacy: .public) unreadable: \(String(describing: error), privacy: .public); moving it aside")
            let salvage = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: salvage)
            return fallback
        }
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(value)
        let temp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        // `replaceItemAt` is the atomic swap; fall back to a plain move if the
        // destination doesn't exist yet.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
