import Foundation

/// The rendering engine used by a browser pane.
enum BrowserEngine: String, CaseIterable {
    case webkit = "webkit"
    case chromium = "chromium"

    var displayName: String {
        switch self {
        case .webkit: return "WebKit"
        case .chromium: return "Chromium"
        }
    }

    var description: String {
        switch self {
        case .webkit: return "macOS native engine (Safari). Best performance and energy efficiency."
        case .chromium: return "Chromium engine (CEF). Best compatibility with Chrome-targeted web apps."
        }
    }
}
