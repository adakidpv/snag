import Foundation

/// The ticket fields Claude drafts. Every one is editable before filing -- the draft is
/// a starting point, never the final word.
struct DraftedTicket: Codable, Equatable {
    var title: String
    var summary: String
    var stepsToReproduce: [String]
    var expected: String
    var actual: String
    /// Free text rather than an enum: the taxonomy lives in `Board.areas`, which is the
    /// user's to edit, so nothing here can be exhaustive. An area the model returns that
    /// isn't in the configured list is kept as-is rather than failing the draft, and the
    /// Report panel offers it alongside the configured ones.
    var area: String
    var severity: Severity
    var labels: [String]

    /// Structured-output schemas don't support `maxLength`, so the 80-character ceiling
    /// is asked for in the system prompt and enforced here on the way in.
    static let titleLimit = 80

    enum Severity: String, Codable, CaseIterable, Identifiable {
        case blocker, major, minor, cosmetic
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static var empty: DraftedTicket {
        DraftedTicket(
            title: "",
            summary: "",
            stepsToReproduce: [],
            expected: "",
            actual: "",
            area: "",
            severity: .major,
            labels: []
        )
    }

    /// Clamps on a word boundary where there is one close to the limit, so a trimmed
    /// title doesn't end mid-word.
    func clampingTitle() -> DraftedTicket {
        guard title.count > Self.titleLimit else { return self }
        var copy = self
        let cut = title.index(title.startIndex, offsetBy: Self.titleLimit)
        let hard = String(title[title.startIndex..<cut])
        if let space = hard.lastIndex(of: " "), hard.distance(from: space, to: hard.endIndex) < 16 {
            copy.title = String(hard[hard.startIndex..<space])
        } else {
            copy.title = hard
        }
        copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
