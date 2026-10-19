import XCTest

final class JSONFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JSONFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String = "store.json") -> JSONFile<[String]> {
        JSONFile(url: directory.appendingPathComponent(name))
    }

    func testMissingFileReturnsTheFallback() {
        XCTAssertEqual(file().load(fallback: ["seed"]), ["seed"])
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = file()
        try store.save(["a", "b", "c"])
        XCTAssertEqual(store.load(fallback: []), ["a", "b", "c"])
    }

    /// The first save has no file to replace; the second does. Both paths matter,
    /// because the atomic swap is only reachable on the second.
    func testOverwritingAnExistingFileWorks() throws {
        let store = file()
        try store.save(["first"])
        try store.save(["second"])
        XCTAssertEqual(store.load(fallback: []), ["second"])
    }

    func testSaveCreatesMissingIntermediateDirectories() throws {
        let nested = JSONFile<[String]>(
            url: directory.appendingPathComponent("a/b/c/store.json")
        )
        try nested.save(["deep"])
        XCTAssertEqual(nested.load(fallback: []), ["deep"])
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        let store = file()
        try store.save(["one"])
        try store.save(["two"])

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "found leftover temp files: \(leftovers)")
    }

    /// A corrupt file must not wedge the app on every launch -- it's moved aside and
    /// the caller carries on with the fallback.
    func testCorruptFileIsMovedAsideAndFallbackReturned() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("{ this is not json".utf8).write(to: url)

        let store = JSONFile<[String]>(url: url)
        XCTAssertEqual(store.load(fallback: ["recovered"]), ["recovered"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let salvaged = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt-") }
        XCTAssertEqual(salvaged.count, 1, "the bad file should be kept for inspection")
    }

    func testDatesSurviveTheRoundTrip() throws {
        struct Row: Codable, Equatable { var at: Date }
        let store = JSONFile<[Row]>(url: directory.appendingPathComponent("dates.json"))
        // Whole seconds: ISO-8601 encoding doesn't carry sub-second precision.
        let when = Date(timeIntervalSince1970: 1_792_185_475)
        try store.save([Row(at: when)])
        XCTAssertEqual(store.load(fallback: []), [Row(at: when)])
    }
}
