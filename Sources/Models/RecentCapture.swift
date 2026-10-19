import Foundation

/// A detected capture that hasn't been reported yet.
///
/// The brief is specific that dismissing a toast creates nothing, so detection
/// deliberately stops here: the file is copied into the library (so it survives the
/// user clearing their screenshots folder) and listed under Recent captures, but no
/// `SnagRecord` exists until the user actually reports it.
struct RecentCapture: Codable, Equatable, Identifiable {
    var id: UUID
    /// Filename within the capture library, not the original path.
    var captureFilename: String
    /// Where it was found, kept only so the Finder reveal can prefer the original.
    var originalPath: String
    var mediaType: SnagRecord.MediaType
    var context: CaptureContext
    var detectedAt: Date
    /// Set once reported, so the same capture isn't offered twice and its library file
    /// isn't pruned out from under the record that now owns it.
    var promotedRecordID: UUID?

    init(
        id: UUID = UUID(),
        captureFilename: String,
        originalPath: String,
        mediaType: SnagRecord.MediaType,
        context: CaptureContext,
        detectedAt: Date = Date(),
        promotedRecordID: UUID? = nil
    ) {
        self.id = id
        self.captureFilename = captureFilename
        self.originalPath = originalPath
        self.mediaType = mediaType
        self.context = context
        self.detectedAt = detectedAt
        self.promotedRecordID = promotedRecordID
    }

    var originalURL: URL { URL(fileURLWithPath: originalPath) }
    var isReported: Bool { promotedRecordID != nil }

    /// What the menu bar shows next to the thumbnail.
    var displayHost: String { context.host ?? "No page" }
}
