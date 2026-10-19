import XCTest

/// What the Report panel does when the Inbox moves the ground under it.
///
/// A panel stays open on a snag the Inbox can meanwhile delete or fold into another
/// ticket. The record it writes through is then gone, and because a write to a record
/// that isn't there can't happen, every one of them used to vanish in silence: a typed
/// note saved nothing, and **File in Jira** still made a real issue -- the network call
/// is unconditional -- whose key then had nowhere to go. These cover both halves: a
/// session that follows the merge onto the ticket that survived, and one whose snag was
/// deleted and must refuse to do anything at all.
@MainActor
final class ReportSessionTests: XCTestCase {
    private var root: URL!
    private var library: CaptureLibrary!
    private var store: SnagStore!
    private var settings: AppSettings!
    private var coordinator: CaptureCoordinator!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReportSessionTests-\(UUID().uuidString)", isDirectory: true)
        library = CaptureLibrary(root: root)
        try library.prepare()
        store = SnagStore(library: library)

        // Its own defaults domain, so a test never reads or writes the machine's real
        // settings.
        defaultsName = "ReportSessionTests-\(UUID().uuidString)"
        settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)))
        // A board complete enough that filing is blocked by nothing else -- otherwise
        // "can't file" would prove nothing.
        settings.boards = [
            Board(
                name: "Web",
                site: "example",
                projectID: "10001",
                issueTypeID: "10004",
                mode: .restAPI,
                accountEmail: "qa@example.com"
            )
        ]
        // Never started: starting it would want a live screenshots folder and a browser.
        coordinator = CaptureCoordinator(settings: settings, library: library)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeCapture(secondsAgo: TimeInterval = 0) throws -> RecentCapture {
        let name = "\(UUID().uuidString).png"
        try Data("not-really-a-png".utf8).write(to: library.url(forCaptureNamed: name))
        return RecentCapture(
            captureFilename: name,
            originalPath: "/tmp/\(name)",
            mediaType: .image,
            context: CaptureContext.unknown(),
            detectedAt: Date().addingTimeInterval(-secondsAgo)
        )
    }

    /// A panel opened on a capture, with a note typed and saved -- which is what creates
    /// the record, exactly as the real panel does on its first write.
    private func makeSession(
        for capture: RecentCapture,
        note: String
    ) -> (session: ReportSession, recordID: UUID) {
        let session = ReportSession(
            captures: [capture],
            store: store,
            settings: settings,
            coordinator: coordinator
        )
        session.note = note
        return (session, session.persistNote())
    }

    // MARK: - Merged away while open

    /// The kind outcome: the captures and the note moved to a ticket that still exists,
    /// so the panel moves with them rather than being closed or left writing nowhere.
    func testASessionWhoseSnagWasMergedAwayFollowsTheTicketThatSurvived() throws {
        let keptCapture = try makeCapture(secondsAgo: 600)
        let kept = store.promote(keptCapture, note: "canvas froze", boardID: nil)
        let ownCapture = try makeCapture()
        let (session, ownID) = makeSession(for: ownCapture, note: "console says 500")

        let result = try XCTUnwrap(store.merge(into: kept.id, from: [ownID]))
        session.followMerge(into: result.record, captures: [keptCapture, ownCapture])

        XCTAssertFalse(session.isDetached, "the panel writes to the ticket that survived")
        XCTAssertEqual(session.recordID, kept.id)
        XCTAssertEqual(
            session.captures.map(\.captureFilename),
            result.record.captureFilenames,
            "and carries exactly what the ticket does"
        )
        XCTAssertEqual(session.note, "canvas froze\n\nconsole says 500")
        XCTAssertNotNil(session.notice, "the panel has to say where it went")
        XCTAssertNil(session.filingBlockedReason, "filing is available again")

        // The point of all of it: a write from the panel now lands.
        session.note += "\n\nstill broken after a refresh"
        session.persistNote()
        XCTAssertEqual(store.record(id: kept.id)?.note, session.note)
        XCTAssertEqual(store.record(id: kept.id)?.captureFilenames, result.record.captureFilenames)
    }

    /// A note typed since the last save was never on any record, so the merge can't have
    /// carried it over. It isn't the merge's to lose -- the panel brings it along, and
    /// keeps the overlap rather than guessing where the saved part ends.
    func testANoteTypedSinceTheLastSaveComesAlong() throws {
        let keptCapture = try makeCapture(secondsAgo: 600)
        let kept = store.promote(keptCapture, note: "canvas froze", boardID: nil)
        let ownCapture = try makeCapture()
        let (session, ownID) = makeSession(for: ownCapture, note: "console says 500")
        session.note = "console says 500, and the tab locks up"

        let result = try XCTUnwrap(store.merge(into: kept.id, from: [ownID]))
        session.followMerge(into: result.record, captures: [keptCapture, ownCapture])

        XCTAssertTrue(
            session.note.contains("the tab locks up"),
            "what was typed in the panel was dropped: \(session.note)"
        )
        XCTAssertEqual(
            store.record(id: kept.id)?.note,
            session.note,
            "and it's saved on the ticket, not just on screen"
        )
    }

    /// The other side of a merge: this panel's snag is the one that was kept, so its
    /// record is still there -- but its capture list and its note are now short of what
    /// the merge put on the ticket, and the next save would write both back off it.
    func testTheKeptSnagsPanelLearnsWhatJoinedIt() throws {
        let ownCapture = try makeCapture(secondsAgo: 600)
        let (session, ownID) = makeSession(for: ownCapture, note: "canvas froze")
        let otherCapture = try makeCapture()
        let other = store.promote(otherCapture, note: "console says 500", boardID: nil)

        let result = try XCTUnwrap(store.merge(into: ownID, from: [other.id]))
        session.followMerge(into: result.record, captures: [ownCapture, otherCapture])

        XCTAssertEqual(session.recordID, ownID, "it kept its own ticket")
        XCTAssertEqual(session.captures.map(\.captureFilename), result.record.captureFilenames)
        XCTAssertEqual(session.note, "canvas froze\n\nconsole says 500")
        XCTAssertNotNil(session.notice)

        session.persistNote()
        XCTAssertEqual(
            store.record(id: ownID)?.captureFilenames,
            result.record.captureFilenames,
            "the panel wrote its pre-merge capture list back and stranded the rest"
        )
        XCTAssertEqual(store.record(id: ownID)?.note, "canvas froze\n\nconsole says 500")
    }

    /// And the backstop, for a merge the panel somehow didn't follow: a session pointing
    /// at a record that isn't there files nothing.
    func testASessionLeftOnAMergedAwaySnagCannotFile() async throws {
        let kept = store.promote(try makeCapture(secondsAgo: 600), note: "canvas froze", boardID: nil)
        let (session, ownID) = makeSession(for: try makeCapture(), note: "console says 500")
        XCTAssertTrue(session.canFile, "nothing else may be what blocks filing below")

        store.merge(into: kept.id, from: [ownID])

        XCTAssertTrue(session.isDetached)
        XCTAssertFalse(session.canFile)
        await session.file()
        XCTAssertNil(session.filedKey, "an issue was filed with nothing to record its key on")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.record(id: kept.id)?.jiraKey, "and it landed on the wrong ticket")
        XCTAssertEqual(store.record(id: kept.id)?.status, .draft)
    }

    // MARK: - Deleted while open

    /// Deletion takes the capture files too, so there is nothing to draft from, nothing
    /// to save to and nothing to attach. The app closes this panel; whatever is left of
    /// the session must refuse rather than pretend.
    func testADeletedSnagsSessionSavesNothingAndFilesNothing() async throws {
        let capture = try makeCapture()
        let (session, recordID) = makeSession(for: capture, note: "canvas froze")
        XCTAssertTrue(session.canFile)
        XCTAssertFalse(session.isDetached)

        store.delete(id: recordID)

        XCTAssertTrue(session.isDetached)
        XCTAssertFalse(session.canFile)
        XCTAssertFalse(session.canDraft)
        let reason = try XCTUnwrap(session.filingBlockedReason)
        XCTAssertTrue(reason.contains("Inbox"), "the panel has to say why: \(reason)")
        XCTAssertEqual(session.draftBlockedReason, reason, "drafting is blocked for the same reason")

        session.note = "typed into a panel whose snag is gone"
        session.persistNote()
        XCTAssertTrue(store.records.isEmpty, "a note resurrected a deleted snag")

        await session.file()
        XCTAssertNil(session.filedKey)
        XCTAssertTrue(store.records.isEmpty)
    }

    /// Adding a capture to a detached report would take it out of Recent captures and
    /// put it nowhere.
    func testADeletedSnagsSessionTakesNoMoreCaptures() throws {
        let (session, recordID) = makeSession(for: try makeCapture(), note: "canvas froze")
        store.delete(id: recordID)

        session.add(try makeCapture())

        XCTAssertEqual(session.captures.count, 1)
    }
}
