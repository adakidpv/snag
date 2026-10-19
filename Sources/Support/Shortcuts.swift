import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌃⌥⌘B, per the brief. Rebindable in Settings; `KeyboardShortcuts` persists any
    /// change itself, so there's nothing to mirror into `AppSettings`.
    static let openReport = Self(
        "openReport",
        default: .init(.b, modifiers: [.control, .option, .command])
    )
}
