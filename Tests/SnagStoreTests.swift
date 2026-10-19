import XCTest

@MainActor
final class SnagStoreTests: XCTestCase {
    private var root: URL!
    private var library: CaptureLibrary!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnagStoreTests-\(UUID().uuidString)", isDirectory: true)
        library = CaptureLibrary(root: root)
        try library.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Writes a stand-in capture file so file-deleting behaviour is observable.
    private func makeCapture(host: String? = "app.example.com", env: String? = "prod") throws -> RecentCapture {
        let name = "\(UUID().uuidString).png"
        try Data("not-really-a-png".utf8).write(to: library.url(forCaptureNamed: name))

        var context = CaptureContext.unknown()
        context.url = host.map { "https://\($0)/sites/42" }
        context.env = env
        return RecentCapture(
            captureFilename: name,
            originalPath: "/tmp/\(name)",
            mediaType: .image,
            context: context
        )
    }

    private func draft(title: String) -> DraftedTicket {
        var t = DraftedTicket.empty
        t.title = title
        return t
    }

    // MARK: - Promotion

    func testPromoteCreatesADraftRecord() throws {
        let store = SnagStore(library: library)
        let capture = try makeCapture()

        let record = store.promote(capture, note: "canvas didn't update", boardID: nil)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(record.status, .draft)
        XCTAssertEqual(record.note, "canvas didn't update")
        XCTAssertEqual(record.captureFilename, capture.captureFilename)
        XCTAssertEqual(record.context.env, "prod")
    }

    func testRecordsAreNewestFirst() throws {
        let store = SnagStore(library: library)
        let first = store.promote(try makeCapture(), note: "first", boardID: nil)
        let second = store.promote(try makeCapture(), note: "second", boardID: nil)

        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])
    }

    // MARK: - Persistence

    func testRecordsSurviveAFreshStoreOnTheSameLibrary() throws {
        let store = SnagStore(library: library)
        let record = store.promote(try makeCapture(), note: "persist me", boardID: nil)
        store.modify(id: record.id) { $0.draft = self.draft(title: "Canvas doesn't update") }

        let reloaded = SnagStore(library: library)

        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.note, "persist me")
        XCTAssertEqual(reloaded.records.first?.draft?.title, "Canvas doesn't update")
    }

    // MARK: - Status and keys

    func testSetStatusMovesTheRecord() throws {
        let store = SnagStore(library: library)
        let record = store.promote(try makeCapture(), note: "", boardID: nil)

        store.setStatus(.filed, for: record.id)

        XCTAssertEqual(store.record(id: record.id)?.status, .filed)
        XCTAssertEqual(store.count(of: .filed), 1)
        XCTAssertEqual(store.count(of: .draft), 0)
    }

    func testPastedJiraKeyIsNormalisedOnTheWayIn() throws {
        let store = SnagStore(library: library)
        let record = store.promote(try makeCapture(), note: "", boardID: nil)

        store.setJiraKey("  bug-412 ", for: record.id)
        XCTAssertEqual(store.record(id: record.id)?.jiraKey, "BUG-412")

        store.setJiraKey("https://example.atlassian.net/browse/BUG-9", for: record.id)
        XCTAssertEqual(store.record(id: record.id)?.jiraKey, "BUG-9")
    }

    func testUnparseableJiraKeyClearsRatherThanStoringJunk() throws {
        let store = SnagStore(library: library)
        let record = store.promote(try makeCapture(), note: "", boardID: nil)
        store.setJiraKey("BUG-412", for: record.id)

        store.setJiraKey("not a key", for: record.id)

        XCTAssertNil(store.record(id: record.id)?.jiraKey)
    }

    // MARK: - Deletion

    func testDeleteRemovesTheRecordAndItsCaptureFile() throws {
        let store = SnagStore(library: library)
        let capture = try makeCapture()
        let record = store.promote(capture, note: "", boardID: nil)
        let fileURL = library.url(forCaptureNamed: capture.captureFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.delete(id: record.id)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A write to a record that has left the Inbox used to do nothing at all, silently.
    /// That is how a Report panel open on a deleted or merged-away snag came to look
    /// like it was still saving notes -- and to file a real Jira issue with nothing left
    /// to record its key on. The write still can't happen; it just can't hide.
    func testWritingToARecordThatHasLeftTheInboxIsReported() throws {
        let store = SnagStore(library: library)
        let gone = store.promote(try makeCapture(), note: "", boardID: nil)
        let kept = store.promote(try makeCapture(), note: "", boardID: nil)
        store.delete(id: gone.id)

        XCTAssertFalse(
            store.modify(id: gone.id) { $0.note = "typed after the delete" },
            "a write to a record that isn't there has to report that it didn't happen"
        )
        XCTAssertEqual(store.records.map(\.id), [kept.id], "and must not resurrect it")

        XCTAssertTrue(store.modify(id: kept.id) { $0.note = "typed on a live record" })
        XCTAssertEqual(store.record(id: kept.id)?.note, "typed on a live record")
    }

    // MARK: - Filtering and search

    func testFilterByStatus() throws {
        let store = SnagStore(library: library)
        let a = store.promote(try makeCapture(), note: "a", boardID: nil)
        _ = store.promote(try makeCapture(), note: "b", boardID: nil)
        store.setStatus(.filed, for: a.id)

        XCTAssertEqual(store.filtered(status: .filed, query: "").map(\.id), [a.id])
        XCTAssertEqual(store.filtered(status: .draft, query: "").count, 1)
        XCTAssertEqual(store.filtered(status: nil, query: "").count, 2)
    }

    func testSearchMatchesNoteTitleURLAndKey() throws {
        let store = SnagStore(library: library)
        let record = store.promote(
            try makeCapture(host: "staging.example.com"),
            note: "publish button spins forever",
            boardID: nil
        )
        store.modify(id: record.id) { $0.draft = self.draft(title: "Publish never completes") }
        store.setJiraKey("BUG-412", for: record.id)
        _ = store.promote(try makeCapture(host: "example.com"), note: "unrelated", boardID: nil)

        XCTAssertEqual(store.filtered(status: nil, query: "spins").count, 1, "note")
        XCTAssertEqual(store.filtered(status: nil, query: "never completes").count, 1, "title")
        XCTAssertEqual(store.filtered(status: nil, query: "staging.example.com").count, 1, "url")
        XCTAssertEqual(store.filtered(status: nil, query: "bug-412").count, 1, "key")
        XCTAssertEqual(store.filtered(status: nil, query: "nothing here").count, 0)
    }

    func testSearchIsCaseInsensitiveAndIgnoresSurroundingSpace() throws {
        let store = SnagStore(library: library)
        _ = store.promote(try makeCapture(), note: "Canvas Did Not Update", boardID: nil)

        XCTAssertEqual(store.filtered(status: nil, query: "CANVAS").count, 1, "case")
        XCTAssertEqual(store.filtered(status: nil, query: "  canvas DID  ").count, 1, "outer space")
    }

    /// Search is a plain substring match, not a token match. Worth pinning down: it
    /// means a typo'd double space finds nothing, which is the behaviour to change if
    /// the search ever feels too literal.
    func testSearchIsASubstringMatchNotATokenMatch() throws {
        let store = SnagStore(library: library)
        _ = store.promote(try makeCapture(), note: "Canvas Did Not Update", boardID: nil)

        XCTAssertEqual(store.filtered(status: nil, query: "canvas  did").count, 0)
        XCTAssertEqual(store.filtered(status: nil, query: "did not").count, 1)
    }

    func testStatusAndQueryCombine() throws {
        let store = SnagStore(library: library)
        let filed = store.promote(try makeCapture(), note: "publish broken", boardID: nil)
        _ = store.promote(try makeCapture(), note: "publish broken too", boardID: nil)
        store.setStatus(.filed, for: filed.id)

        XCTAssertEqual(store.filtered(status: .filed, query: "publish").map(\.id), [filed.id])
    }

    // MARK: - Orphan reaping

    func testReapDeletesUnreferencedFilesOnly() throws {
        let store = SnagStore(library: library)
        let kept = try makeCapture()
        _ = store.promote(kept, note: "", boardID: nil)

        // An orphan, backdated past the safety floor.
        let orphanName = "orphan.png"
        let orphanURL = library.url(forCaptureNamed: orphanName)
        try Data("x".utf8).write(to: orphanURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: orphanURL.path
        )

        let reaped = library.reapOrphans(referenced: store.referencedCaptureFilenames)

        XCTAssertEqual(reaped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: library.url(forCaptureNamed: kept.captureFilename).path)
        )
    }

    /// A file copied in a moment ago may not have its owning entry written yet, so the
    /// reaper must leave recent files alone even when nothing refers to them.
    func testReapSparesRecentlyWrittenFiles() throws {
        let orphanURL = library.url(forCaptureNamed: "just-arrived.png")
        try Data("x".utf8).write(to: orphanURL)

        let reaped = library.reapOrphans(referenced: [])

        XCTAssertEqual(reaped, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
    }
}
