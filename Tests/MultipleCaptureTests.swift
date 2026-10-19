import XCTest

/// One ticket, several captures.
///
/// The risky parts of that change aren't the UI: they're the orphan reaper (which
/// deletes capture files nothing refers to, and so would eat the extras if anything
/// only looked at the primary), the stored shape (an inbox written by a single-capture
/// version still has to load), and the request sent to the model.
@MainActor
final class MultipleCaptureTests: XCTestCase {
    private var root: URL!
    private var library: CaptureLibrary!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MultiCaptureTests-\(UUID().uuidString)", isDirectory: true)
        library = CaptureLibrary(root: root)
        try library.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeCapture(
        mediaType: SnagRecord.MediaType = .image,
        detectedAt: Date = Date()
    ) throws -> RecentCapture {
        let name = "\(UUID().uuidString).\(mediaType == .video ? "mov" : "png")"
        try Data("not-really-a-png".utf8).write(to: library.url(forCaptureNamed: name))
        return RecentCapture(
            captureFilename: name,
            originalPath: "/tmp/\(name)",
            mediaType: mediaType,
            context: CaptureContext.unknown(),
            detectedAt: detectedAt
        )
    }

    /// Ages every capture file past the reaper's floor, so a run of the reaper is a
    /// real test of what's referenced rather than of the age guard.
    private func age(_ captures: [RecentCapture]) throws {
        let old = Date().addingTimeInterval(-600)
        for capture in captures {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: library.url(forCaptureNamed: capture.captureFilename).path
            )
        }
    }

    private func fileExists(_ capture: RecentCapture) -> Bool {
        FileManager.default.fileExists(
            atPath: library.url(forCaptureNamed: capture.captureFilename).path
        )
    }

    // MARK: - Storage

    func testPromotingSeveralCapturesKeepsThemInOrder() throws {
        let store = SnagStore(library: library)
        let first = try makeCapture()
        let second = try makeCapture()
        let third = try makeCapture()

        let record = store.promote([first, second, third], note: "three shots", boardID: nil)

        XCTAssertEqual(
            record.captureFilenames,
            [first.captureFilename, second.captureFilename, third.captureFilename]
        )
        XCTAssertEqual(record.captureFilename, first.captureFilename, "the primary is the first")
        XCTAssertTrue(record.hasMultipleCaptures)
    }

    /// The one that would quietly delete the user's screenshots: `reapOrphans` spares
    /// only files something still refers to, so every capture on every record has to be
    /// in the referenced set -- not just the primary.
    func testEveryCaptureOnARecordIsProtectedFromTheReaper() throws {
        let store = SnagStore(library: library)
        let captures = try (0..<3).map { _ in try makeCapture() }
        store.promote(captures, note: "three shots", boardID: nil)

        let referenced = store.referencedCaptureFilenames
        for capture in captures {
            XCTAssertTrue(
                referenced.contains(capture.captureFilename),
                "\(capture.captureFilename) would be reaped"
            )
        }

        // Age the files past the reaper's floor and run it for real.
        try age(captures)
        library.reapOrphans(referenced: referenced)

        for capture in captures {
            XCTAssertTrue(fileExists(capture), "\(capture.captureFilename) was deleted despite being on a record")
        }
    }

    func testDeletingARecordDeletesAllOfItsCaptures() throws {
        let store = SnagStore(library: library)
        let captures = try (0..<3).map { _ in try makeCapture() }
        let record = store.promote(captures, note: "three shots", boardID: nil)

        store.delete(id: record.id)

        for capture in captures {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: library.url(forCaptureNamed: capture.captureFilename).path
                ),
                "\(capture.captureFilename) outlived its record"
            )
        }
    }

    // MARK: - Merging in the Inbox

    /// Four shots taken ten minutes apart are four records by the time the user thinks
    /// of filing them together, so the Inbox merges records rather than captures.
    func testMergingMovesEveryCaptureOntoTheSurvivingRecord() throws {
        let store = SnagStore(library: library)
        let first = try makeCapture(detectedAt: Date().addingTimeInterval(-600))
        let second = try makeCapture(detectedAt: Date().addingTimeInterval(-300))
        let third = try makeCapture()
        let oldest = store.promote(first, note: "canvas froze", boardID: nil)
        let middle = store.promote(second, note: "", boardID: nil)
        let newest = store.promote(third, note: "", boardID: nil)

        let result = try XCTUnwrap(store.merge(into: oldest.id, from: [newest.id, middle.id]))

        XCTAssertEqual(
            result.record.captureFilenames,
            [first.captureFilename, second.captureFilename, third.captureFilename],
            "the surviving snag's capture leads, then the rest oldest record first"
        )
        XCTAssertEqual(result.movedCaptureFilenames, [second.captureFilename, third.captureFilename])
        XCTAssertEqual(store.records.count, 1, "the merged-away records leave the Inbox")
        XCTAssertEqual(store.record(id: oldest.id)?.captureFilenames.count, 3)
        XCTAssertNil(store.record(id: middle.id))
        XCTAssertNil(store.record(id: newest.id))
    }

    /// The whole point of not reusing `delete(id:)`: it takes the record's files with
    /// it, which after a merge are the merged ticket's screenshots.
    func testMergingDeletesNoCaptureFile() throws {
        let store = SnagStore(library: library)
        let captures = try (0..<3).map { _ in try makeCapture() }
        let records = captures.map { store.promote($0, note: "", boardID: nil) }

        store.merge(into: records[0].id, from: [records[1].id, records[2].id])

        for capture in captures {
            XCTAssertTrue(fileExists(capture), "\(capture.captureFilename) was deleted by the merge")
        }
    }

    /// And the delayed version of the same disaster: a file the store no longer claims
    /// is deleted by the reaper five minutes later, not on the spot.
    func testEveryMergedCaptureIsProtectedFromTheReaper() throws {
        let store = SnagStore(library: library)
        let captures = try (0..<3).map { _ in try makeCapture() }
        let records = captures.map { store.promote($0, note: "", boardID: nil) }

        store.merge(into: records[0].id, from: [records[1].id, records[2].id])

        let referenced = store.referencedCaptureFilenames
        for capture in captures {
            XCTAssertTrue(
                referenced.contains(capture.captureFilename),
                "\(capture.captureFilename) would be reaped after the merge"
            )
        }

        try age(captures)
        library.reapOrphans(referenced: referenced)

        for capture in captures {
            XCTAssertTrue(fileExists(capture), "\(capture.captureFilename) was reaped after the merge")
        }
    }

    /// The surviving snag is the ticket: its id, date, key and status are what the
    /// merged record keeps.
    func testTheSurvivingRecordKeepsItsIdentity() throws {
        let store = SnagStore(library: library)
        let old = Date().addingTimeInterval(-900)
        let kept = store.promote(try makeCapture(detectedAt: old), note: "canvas froze", boardID: nil)
        let other = store.promote(try makeCapture(), note: "", boardID: nil)
        store.setJiraKey("abc-412", for: kept.id)
        store.setStatus(.filed, for: kept.id)

        let result = try XCTUnwrap(store.merge(into: kept.id, from: [other.id]))

        XCTAssertEqual(result.record.id, kept.id)
        XCTAssertEqual(result.record.createdAt, old)
        XCTAssertEqual(result.record.jiraKey, "ABC-412")
        XCTAssertEqual(result.record.status, .filed)
    }

    /// A note is the only part of a merged-away snag the user typed, so it comes along
    /// rather than being dropped on the floor.
    func testMergingCarriesTheOtherNotesOver() throws {
        let store = SnagStore(library: library)
        let kept = store.promote(
            try makeCapture(detectedAt: Date().addingTimeInterval(-600)),
            note: "canvas froze",
            boardID: nil
        )
        let other = store.promote(try makeCapture(), note: "console says 500", boardID: nil)

        let result = try XCTUnwrap(store.merge(into: kept.id, from: [other.id]))

        XCTAssertEqual(result.record.note, "canvas froze\n\nconsole says 500")
    }

    /// Four is the ceiling everywhere else, so the Inbox can't be the way round it.
    /// The refusal is a sentence the pane shows, not a silent truncation.
    func testMergingRefusesMoreCapturesThanATicketCarries() throws {
        let store = SnagStore(library: library)
        let three = try (0..<3).map { _ in try makeCapture() }
        let two = try (0..<2).map { _ in try makeCapture() }
        let first = store.promote(three, note: "three shots", boardID: nil)
        let second = store.promote(two, note: "two more", boardID: nil)

        XCTAssertEqual(
            store.mergeRefusal(for: [first.id, second.id]),
            .tooManyCaptures(count: 5)
        )
        XCTAssertNil(store.merge(into: first.id, from: [second.id]))
        XCTAssertEqual(store.records.count, 2, "a refused merge changes nothing")
        XCTAssertEqual(store.record(id: first.id)?.captureFilenames.count, 3)
    }

    /// A record carries one media type, so folding a recording into a screenshot
    /// ticket would mislabel every capture on it.
    func testMergingRefusesMixedMedia() throws {
        let store = SnagStore(library: library)
        let shot = store.promote(try makeCapture(), note: "", boardID: nil)
        let recording = store.promote(try makeCapture(mediaType: .video), note: "", boardID: nil)

        XCTAssertEqual(store.mergeRefusal(for: [shot.id, recording.id]), .mixedMedia)
        XCTAssertNil(store.merge(into: shot.id, from: [recording.id]))
        XCTAssertEqual(store.records.count, 2)
    }

    func testMergingOneRecordIsRefused() throws {
        let store = SnagStore(library: library)
        let only = store.promote(try makeCapture(), note: "", boardID: nil)

        XCTAssertEqual(store.mergeRefusal(for: [only.id]), .nothingToMerge)
        XCTAssertNil(store.merge(into: only.id, from: []))
        XCTAssertNil(store.merge(into: only.id, from: [UUID()]), "an id that names nothing merges nothing")
        XCTAssertEqual(store.records.count, 1)
    }

    /// The merged record is the one that persists: a reload has to find the ticket,
    /// not the records it was made of.
    func testAMergedTicketSurvivesAReload() throws {
        let store = SnagStore(library: library)
        let captures = try (0..<2).map { _ in try makeCapture() }
        let records = captures.map { store.promote($0, note: "", boardID: nil) }
        store.merge(into: records[0].id, from: [records[1].id])

        let reloaded = SnagStore(library: library)

        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(
            reloaded.record(id: records[0].id)?.captureFilenames,
            captures.map(\.captureFilename)
        )
        XCTAssertEqual(reloaded.referencedCaptureFilenames, Set(captures.map(\.captureFilename)))
    }

    // MARK: - Stored shape

    /// An inbox written before a ticket could hold more than one capture names a single
    /// `captureFilename`. Failing to read it would empty someone's inbox.
    func testRecordWrittenWithASingleCaptureStillDecodes() throws {
        let json = #"""
        {"id":"3E2C1A90-5B4D-4F7E-8A21-9C0D6B3F1E54",
         "createdAt":792185475,"captureFilename":"snag-1.png","mediaType":"image",
         "context":{"capturedAt":792185475,"osVersion":"macOS 15.0"},
         "note":"canvas didn't update","status":"filed","jiraKey":"ABC-412"}
        """#
        let record = try JSONDecoder().decode(SnagRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.captureFilenames, ["snag-1.png"])
        XCTAssertEqual(record.captureFilename, "snag-1.png")
        XCTAssertFalse(record.hasMultipleCaptures)
        XCTAssertEqual(record.jiraKey, "ABC-412")
    }

    /// And the other direction: a record written now still has to be readable by a
    /// version that only knows the singular key, so the primary is written too.
    func testRecordWritesThePrimaryUnderTheOldKeyAsWell() throws {
        var record = SnagRecord(
            captureFilenames: ["a.png", "b.png"],
            mediaType: .image,
            context: .unknown()
        )
        record.note = "two shots"

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["captureFilename"] as? String, "a.png")
        XCTAssertEqual(json["captureFilenames"] as? [String], ["a.png", "b.png"])

        let roundTripped = try JSONDecoder().decode(SnagRecord.self, from: data)
        XCTAssertEqual(roundTripped.captureFilenames, ["a.png", "b.png"])
    }

    func testBothKeysPresentPrefersTheArray() throws {
        let json = #"""
        {"id":"3E2C1A90-5B4D-4F7E-8A21-9C0D6B3F1E54",
         "createdAt":792185475,
         "captureFilename":"a.png","captureFilenames":["a.png","b.png"],
         "mediaType":"image",
         "context":{"capturedAt":792185475,"osVersion":"macOS 15.0"},
         "note":"","status":"draft"}
        """#
        let record = try JSONDecoder().decode(SnagRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.captureFilenames, ["a.png", "b.png"])
    }

    // MARK: - What the ticket promises

    /// An engineer reading "screenshot attached" and finding one of three wastes their
    /// time, so the footer counts.
    func testFooterCountsTheAttachments() {
        XCTAssertEqual(
            TicketBody.Attachment.automatic(count: 1).footer,
            "Captured with Snag — screenshot attached."
        )
        XCTAssertEqual(
            TicketBody.Attachment.automatic(count: 3).footer,
            "Captured with Snag — 3 screenshots attached."
        )
        XCTAssertEqual(
            TicketBody.Attachment.manual(count: 2).footer,
            "Captured with Snag — 2 screenshots attached manually."
        )
        XCTAssertEqual(
            TicketBody.Attachment.automatic.footer,
            TicketBody.Attachment.automatic(count: 1).footer,
            "the shorthand still means one"
        )
    }
}
