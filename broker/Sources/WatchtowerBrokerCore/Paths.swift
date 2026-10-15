import Foundation

public enum BrokerPaths {
    /// Override the directory used for sockets, pid files, and scrollback.
    /// When nil, defaults to ~/Library/Application Support/Watchtower.
    public static var rootOverride: URL?

    public static var root: URL {
        if let override = rootOverride { return override }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Watchtower", isDirectory: true)
    }

    public static var socketURL: URL { root.appendingPathComponent("broker.sock") }
    public static var pidFileURL: URL { root.appendingPathComponent("broker.pid") }
    public static var scrollbackDir: URL { root.appendingPathComponent("scrollback", isDirectory: true) }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
    }

    public static func scrollbackURL(paneId: UUID) -> URL {
        scrollbackDir.appendingPathComponent("\(paneId.uuidString).log")
    }
}
