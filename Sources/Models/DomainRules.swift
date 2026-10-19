import Foundation

/// Which hosts are worth a toast, and what environment tag each one maps to.
///
/// Kept as a pure value type so the matching rules can be tested without the app: the
/// decision "should this capture interrupt the user?" is the one piece of this app that
/// is both easy to get subtly wrong and annoying when it is.
struct DomainRules: Codable, Equatable {
    /// Hosts that should raise a toast. A rule matches the host itself and any
    /// subdomain of it, so `app.example.com` covers `www.app.example.com`.
    var watchedDomains: [String]
    /// Host suffix to environment tag. Resolved longest-suffix-first, so a rule for
    /// `staging.example.com` wins over one for `example.com`.
    var environmentMap: [String: String]

    /// Empty on a fresh install: Snag has no idea which sites you care about, and
    /// guessing would raise a toast on every screenshot you take. Onboarding fills this.
    static let `default` = DomainRules(watchedDomains: [], environmentMap: [:])

    func isWatched(host: String?) -> Bool {
        guard let host = Self.normalize(host) else { return false }
        return watchedDomains.contains { rule in
            guard let rule = Self.normalize(rule) else { return false }
            return host == rule || host.hasSuffix("." + rule)
        }
    }

    /// Longest matching suffix wins, so adding a more specific rule never needs the
    /// broader one removed.
    func environment(forHost host: String?) -> String? {
        guard let host = Self.normalize(host) else { return nil }
        return environmentMap
            .compactMap { rule, tag -> (Int, String)? in
                guard let rule = Self.normalize(rule) else { return nil }
                guard host == rule || host.hasSuffix("." + rule) else { return nil }
                return (rule.count, tag)
            }
            .max { $0.0 < $1.0 }?
            .1
    }

    /// Lowercases, strips a trailing dot and a leading `www.`, and tolerates a full URL
    /// being pasted into the domain field in Settings.
    static func normalize(_ value: String?) -> String? {
        guard var s = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !s.isEmpty else { return nil }
        if s.contains("://"), let host = URLComponents(string: s)?.host {
            s = host.lowercased()
        }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s.isEmpty ? nil : s
    }
}
