import Foundation
import Observation

/// The Inbox: every reported capture, persisted as one JSON file.
///
/// A plain file rather than SQLite, deliberately. This is one person's bug inbox --
/// hundreds of rows, not millions -- so loading the lot into an array makes filtering
/// and search a predicate over memory, and removes a dependency, a schema and a
/// migration path that would have earned nothing at this size. Swapping in GRDB later
/// means reimplementing this one type.
@Observable
@MainActor
final class SnagStore {
    private(set) var records: [SnagRecord] = []

    private let file: JSONFile<[SnagRecord]>
    private let library: CaptureLibrary

    init(library: CaptureLibrary = CaptureLibrary()) {
        self.library = library
        self.file = JSONFile(url: library.storeFile)
        self.records = file.load(fallback: []).sorted { $0.createdAt > $1.createdAt }
        Log.store.notice("loaded \(self.records.count, privacy: .public) snag(s)")
    }

    /// Capture files the records own, for the orphan reaper. Every capture of every
    /// record, not just the primary one -- miss the extras and the reaper deletes them
    /// five minutes after they're attached.
    var referencedCaptureFilenames: Set<String> {
        Set(records.flatMap(\.captureFilenames))
    }

    func record(id: UUID) -> SnagRecord? {
        records.first { $0.id == id }
    }

    func captureURL(for record: SnagRecord) -> URL {
        library.url(forCaptureNamed: record.captureFilename)
    }

    /// Every capture on the record, primary first.
    func captureURLs(for record: SnagRecord) -> [URL] {
        record.captureFilenames.map { library.url(forCaptureNamed: $0) }
    }

    // MARK: - Writing

    /// Turns a detected capture into a record. The capture file is already in the
    /// library, so this only takes ownership of it.
    /// The one-capture case, which is most of them.
    @discardableResult
    func promote(
        _ capture: RecentCapture,
        note: String,
        boardID: UUID?,
        context: CaptureContext? = nil
    ) -> SnagRecord {
        promote([capture], note: note, boardID: boardID, context: context)
    }

    /// Turns the captures on one report into a record, primary first.
    ///
    /// `context` overrides the primary capture's own, for a page the user corrected in
    /// the Report panel before the record existed.
    @discardableResult
    func promote(
        _ captures: [RecentCapture],
        note: String,
        boardID: UUID?,
        context: CaptureContext? = nil
    ) -> SnagRecord {
        precondition(!captures.isEmpty, "a record always owns at least one capture")
        let capture = captures[0]
        let record = SnagRecord(
            createdAt: capture.detectedAt,
            captureFilenames: captures.map(\.captureFilename),
            mediaType: capture.mediaType,
            context: context ?? capture.context,
            note: note,
            status: .draft,
            boardID: boardID
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func update(_ record: SnagRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        persist()
    }

    /// Mutates in place so callers don't have to read-modify-write a whole record.
    ///
    /// Returns whether the record was there to change, and says so in the log when it
    /// wasn't. A record can leave the Inbox while something is still writing to it --
    /// deleted, or merged into another ticket -- and a write that vanishes without a
    /// trace is how a Report panel came to be able to file a real Jira issue with
    /// nothing left to record its key on.
    @discardableResult
    func modify(id: UUID, _ change: (inout SnagRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            Log.store.error("""
                no snag \(id.uuidString, privacy: .public) to write to -- \
                it has left the Inbox
                """)
            return false
        }
        change(&records[index])
        persist()
        return true
    }

    func setStatus(_ status: SnagRecord.Status, for id: UUID) {
        modify(id: id) { $0.status = status }
    }

    /// Normalises a pasted key (`abc-412`, or a whole browse URL) to `ABC-412`, so
    /// the link built from it actually resolves.
    func setJiraKey(_ raw: String?, for id: UUID) {
        modify(id: id) { $0.jiraKey = JiraKey.normalize(raw) }
    }

    // MARK: - Merging

    /// What a merge changed, so callers can re-point whatever still refers to the
    /// records that went away.
    struct MergeResult {
        var record: SnagRecord
        /// Captures that changed hands, in the order they now sit on the record.
        var movedCaptureFilenames: [String]
    }

    /// Why a merge can't happen, in the words the Inbox shows.
    enum MergeRefusal: Equatable {
        case nothingToMerge
        case tooManyCaptures(count: Int)
        case mixedMedia

        var message: String {
            switch self {
            case .nothingToMerge:
                return "Select two or more snags to report them as one ticket."
            case .tooManyCaptures(let count):
                return "That's \(count) captures. A ticket carries \(SnagRecord.captureLimit)."
            case .mixedMedia:
                return "A ticket is either screenshots or a recording, not both."
            }
        }
    }

    /// Whether these records can become one ticket, and why not when they can't.
    /// Asked by the Inbox before it offers the action, so the refusal is a sentence on
    /// screen rather than a button that does nothing.
    func mergeRefusal(for ids: [UUID]) -> MergeRefusal? {
        let records = orderedRecords(ids: ids)
        guard records.count > 1 else { return .nothingToMerge }
        guard Set(records.map(\.mediaType)).count == 1 else { return .mixedMedia }
        let captures = mergedFilenames(of: records, primary: records[0])
        guard captures.count <= SnagRecord.captureLimit else {
            return .tooManyCaptures(count: captures.count)
        }
        return nil
    }

    /// Folds several records into one ticket, keeping `primaryID`'s identity.
    ///
    /// The Inbox's answer to four screenshots taken ten minutes apart: by then the
    /// first is a record of its own, which neither the toast's Add nor the Report
    /// panel's can reach.
    ///
    /// The primary keeps its id, note, draft, Jira key, status, board and date -- it is
    /// the ticket that survives. The others hand over their captures, oldest record
    /// first, and their notes, which are appended rather than dropped because they are
    /// the only part of a record the user typed. They are then removed *without*
    /// deleting their capture files: those files now belong to the primary, and
    /// `delete(id:)` would take them with it and leave the merged ticket pointing at
    /// nothing.
    ///
    /// Returns nil, having changed nothing, when `mergeRefusal(for:)` would refuse.
    @discardableResult
    func merge(into primaryID: UUID, from otherIDs: [UUID]) -> MergeResult? {
        let ids = [primaryID] + otherIDs
        guard mergeRefusal(for: ids) == nil,
              let primary = record(id: primaryID),
              let primaryIndex = records.firstIndex(where: { $0.id == primaryID })
        else { return nil }

        let ordered = orderedRecords(ids: ids)
        let others = ordered.filter { $0.id != primaryID }
        let filenames = mergedFilenames(of: ordered, primary: primary)

        records[primaryIndex].captureFilenames = filenames
        records[primaryIndex].note = mergedNote(primary: primary, others: others)
        let merged = records[primaryIndex]
        records.removeAll { other in others.contains { $0.id == other.id } }
        persist()

        Log.store.notice("""
            merged \(others.count, privacy: .public) snag(s) into one ticket \
            carrying \(merged.captureFilenames.count, privacy: .public) capture(s)
            """)
        return MergeResult(
            record: merged,
            movedCaptureFilenames: filenames.filter { !primary.captureFilenames.contains($0) }
        )
    }

    /// The records these ids name, oldest first and each one once, so a merge reads in
    /// the order the captures were taken however the rows were clicked.
    private func orderedRecords(ids: [UUID]) -> [SnagRecord] {
        var seen = Set<UUID>()
        return ids
            .filter { seen.insert($0).inserted }
            .compactMap { id in records.first { $0.id == id } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Primary's captures first -- it is the ticket that survives, and its primary
    /// stays the primary -- then the rest in record order, each file once.
    private func mergedFilenames(of records: [SnagRecord], primary: SnagRecord) -> [String] {
        var seen = Set<String>()
        return (primary.captureFilenames + records.flatMap(\.captureFilenames))
            .filter { seen.insert($0).inserted }
    }

    private func mergedNote(primary: SnagRecord, others: [SnagRecord]) -> String {
        let extras = others
            .map(\.note)
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .filter { !primary.note.contains($0) }
        return ([primary.note.nilIfEmpty].compactMap { $0 } + extras).joined(separator: "\n\n")
    }

    func delete(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: index)
        for name in removed.captureFilenames { library.deleteCapture(named: name) }
        persist()
    }

    // MARK: - Reading

    /// Newest first, optionally narrowed by status and a free-text query.
    func filtered(status: SnagRecord.Status?, query: String) -> [SnagRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            if let status, record.status != status { return false }
            guard !needle.isEmpty else { return true }
            return record.searchHaystack.contains(needle)
        }
    }

    func count(of status: SnagRecord.Status) -> Int {
        records.filter { $0.status == status }.count
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try file.save(records)
        } catch {
            Log.store.error("couldn't save the inbox: \(String(describing: error), privacy: .public)")
        }
    }
}
