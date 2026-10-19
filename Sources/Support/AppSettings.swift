import Foundation
import Observation

/// User-facing configuration, persisted as one JSON blob in `UserDefaults`.
///
/// The Anthropic API key and Jira API tokens are deliberately *not* here -- those live
/// in the Keychain. Nothing in this type is a secret.
@Observable
final class AppSettings {
    private static let defaultsKey = "settings.v1"

    struct Stored: Codable, Equatable {
        var domainRules: DomainRules = .default
        var model: String = AppSettings.defaultModel
        var toastEnabled: Bool = true
        var boards: [Board] = []
        var lastUsedBoardID: UUID?

        init() {}

        /// Decoded field by field with fallbacks rather than relying on the synthesized
        /// initialiser, which ignores the property defaults above and throws on a
        /// missing key. Without this, adding one setting in a later version would fail
        /// to decode the whole blob and silently reset the user's configured boards.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            domainRules = (try? container.decodeIfPresent(DomainRules.self, forKey: .domainRules)) .flatMap { $0 } ?? .default
            model = (try? container.decodeIfPresent(String.self, forKey: .model)).flatMap { $0 } ?? AppSettings.defaultModel
            toastEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .toastEnabled)).flatMap { $0 } ?? true
            boards = (try? container.decodeIfPresent([Board].self, forKey: .boards)).flatMap { $0 } ?? []
            lastUsedBoardID = try? container.decodeIfPresent(UUID.self, forKey: .lastUsedBoardID)
        }
    }

    /// Named by the brief. Configurable in Settings; forced tool use is unavailable on
    /// current models, so drafting uses structured outputs instead (see AnthropicClient).
    static let defaultModel = "claude-sonnet-5-5"

    private let defaults: UserDefaults
    private var stored: Stored {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Accessors

    var domainRules: DomainRules {
        get { stored.domainRules }
        set { stored.domainRules = newValue }
    }

    var model: String {
        get { stored.model.nilIfEmpty ?? Self.defaultModel }
        set { stored.model = newValue }
    }

    var toastEnabled: Bool {
        get { stored.toastEnabled }
        set { stored.toastEnabled = newValue }
    }

    var boards: [Board] {
        get { stored.boards }
        set { stored.boards = newValue }
    }

    var lastUsedBoardID: UUID? {
        get { stored.lastUsedBoardID }
        set { stored.lastUsedBoardID = newValue }
    }

    /// The board the Report panel should preselect: last used if it still exists,
    /// otherwise the first configured one.
    var preferredBoard: Board? {
        if let id = stored.lastUsedBoardID, let match = stored.boards.first(where: { $0.id == id }) {
            return match
        }
        return stored.boards.first
    }

    func upsert(board: Board) {
        if let index = stored.boards.firstIndex(where: { $0.id == board.id }) {
            stored.boards[index] = board
        } else {
            stored.boards.append(board)
        }
    }

    func removeBoard(id: UUID) {
        stored.boards.removeAll { $0.id == id }
        if stored.lastUsedBoardID == id { stored.lastUsedBoardID = nil }
    }
}
