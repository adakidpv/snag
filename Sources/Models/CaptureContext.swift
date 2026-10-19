import Foundation

/// Everything Snag could learn about the moment of capture, gathered at detection time.
/// All browser-derived fields are optional: Automation permission can be denied, the
/// frontmost app may not be a browser, and neither case should cost us the capture.
struct CaptureContext: Codable, Equatable {
    var url: String?
    var pageTitle: String?
    var env: String?
    var browserBundleID: String?
    var browserName: String?
    var capturedAt: Date
    var osVersion: String
    var screenResolution: String?

    static func unknown(at date: Date = Date()) -> CaptureContext {
        CaptureContext(
            url: nil,
            pageTitle: nil,
            env: nil,
            browserBundleID: nil,
            browserName: nil,
            capturedAt: date,
            osVersion: Self.currentOSVersion,
            screenResolution: nil
        )
    }

    static var currentOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Host of `url`, which is what domain watching and env mapping both key on.
    var host: String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        return components.host
    }
}
