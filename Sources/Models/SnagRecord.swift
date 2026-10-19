import Foundation

/// One reported capture. Named `SnagRecord` rather than `Snag` so it doesn't collide
/// with the module name inside the app target.
///
/// `captureFilenames` are stored relative to the captures directory, not as absolute
/// paths: the library owns the files once they're copied in, and relative names survive
/// the app moving or the home directory changing.
///
/// A ticket can carry several captures, because one screenshot often doesn't show a
/// bug -- the state before it, the error, the console. They're ordered, primary first:
/// the primary is what the Inbox lists, what the model is pointed at first, and what a
/// manual paste into Jira gets.
struct SnagRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var captureFilenames: [String]
    var mediaType: MediaType
    var context: CaptureContext
    var note: String
    var draft: DraftedTicket?
    var status: Status
    var boardID: UUID?
    var jiraKey: String?

    enum MediaType: String, Codable {
        case image
        case video

        /// Recordings are kept and attachable in v0; only AI frame extraction is deferred.
        var supportsDrafting: Bool { self == .image }
    }

    enum Status: String, Codable, CaseIterable, Identifiable {
        case draft, filed, dismissed
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        captureFilenames: [String],
        mediaType: MediaType,
        context: CaptureContext,
        note: String = "",
        draft: DraftedTicket? = nil,
        status: Status = .draft,
        boardID: UUID? = nil,
        jiraKey: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.captureFilenames = captureFilenames
        self.mediaType = mediaType
        self.context = context
        self.note = note
        self.draft = draft
        self.status = status
        self.boardID = boardID
        self.jiraKey = jiraKey
    }

    /// Four is the ceiling the drafting prompt is written for, and past it the images
    /// cost more than they tell the model. It lives on the record rather than on the
    /// Report panel because the Inbox's merge has to honour the same ceiling.
    static let captureLimit = 4

    /// The capture the ticket leads with. Empty only for a record whose stored array
    /// was empty, which nothing writes.
    var captureFilename: String { captureFilenames.first ?? "" }

    var hasMultipleCaptures: Bool { captureFilenames.count > 1 }

    /// Backing text for the Inbox's search field.
    var searchHaystack: String {
        [draft?.title, note, context.url, context.pageTitle, jiraKey]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, captureFilenames, mediaType, context, note, draft, status
        case boardID, jiraKey
        /// Written by versions that only supported one capture per ticket.
        case captureFilename
    }

    /// Decoded field by field so that an inbox written by an earlier version still
    /// loads: `captureFilename` was a single string, and a record written then has no
    /// `captureFilenames` at all. Falling back per field also means a field added later
    /// can't fail the whole decode and empty someone's inbox.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let names = try? container.decodeIfPresent([String].self, forKey: .captureFilenames),
           !names.isEmpty {
            captureFilenames = names
        } else if let legacy = try? container.decodeIfPresent(String.self, forKey: .captureFilename) {
            captureFilenames = [legacy]
        } else {
            captureFilenames = []
        }
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        context = try container.decode(CaptureContext.self, forKey: .context)
        note = (try? container.decodeIfPresent(String.self, forKey: .note)).flatMap { $0 } ?? ""
        draft = try? container.decodeIfPresent(DraftedTicket.self, forKey: .draft)
        status = (try? container.decodeIfPresent(Status.self, forKey: .status)).flatMap { $0 } ?? .draft
        boardID = try? container.decodeIfPresent(UUID.self, forKey: .boardID)
        jiraKey = try? container.decodeIfPresent(String.self, forKey: .jiraKey)
    }

    /// `captureFilename` is written alongside the array so that an inbox touched by
    /// this version can still be read by one that predates multiple captures -- it sees
    /// the primary and ignores the rest, rather than losing the record.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(captureFilenames, forKey: .captureFilenames)
        try container.encode(captureFilename, forKey: .captureFilename)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(context, forKey: .context)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(draft, forKey: .draft)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(boardID, forKey: .boardID)
        try container.encodeIfPresent(jiraKey, forKey: .jiraKey)
    }
}
