import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.watchtower", category: "WatchtowerConfig")

/// Singleton managing Watchtower's own configuration.
///
/// Reads from `~/.config/watchtower/config.json` at startup.
/// Writes back to the same file when values are changed via the Settings window.
/// If the file does not exist or is missing keys, defaults are used.
class WatchtowerConfig: ObservableObject {
    static let shared = WatchtowerConfig()

    /// The default browser rendering engine for new browser panes.
    @Published var browserEngine: BrowserEngine = .webkit {
        didSet {
            if oldValue != browserEngine {
                save()
            }
        }
    }

    /// The remote debugging port for CEF. 0 = disabled.
    @Published var chromiumRemoteDebuggingPort: Int = 0 {
        didSet {
            if oldValue != chromiumRemoteDebuggingPort {
                save()
            }
        }
    }

    /// Whether the user has dismissed the CLI install prompt permanently.
    @Published var cliInstallDismissed: Bool = false {
        didSet {
            if oldValue != cliInstallDismissed {
                save()
            }
        }
    }

    /// The path to the config file.
    private let configFilePath: URL

    private init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("watchtower")
        configFilePath = configDir.appendingPathComponent("config.json")
        load()
    }

    /// Read the config file and apply values.
    private func load() {
        guard FileManager.default.fileExists(atPath: configFilePath.path) else {
            logger.info("No config file at \(self.configFilePath.path, privacy: .public), using defaults")
            return
        }

        do {
            let data = try Data(contentsOf: configFilePath)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Config file is not a JSON object, using defaults")
                return
            }

            if let engineStr = json["browser-engine"] as? String,
               let engine = BrowserEngine(rawValue: engineStr) {
                browserEngine = engine
            }

            if let port = json["chromium-remote-debugging-port"] as? Int {
                chromiumRemoteDebuggingPort = port
            }

            if let dismissed = json["cli-install-dismissed"] as? Bool {
                cliInstallDismissed = dismissed
            }

            logger.info("Loaded config: browser-engine=\(self.browserEngine.rawValue, privacy: .public), chromium-remote-debugging-port=\(self.chromiumRemoteDebuggingPort)")
        } catch {
            logger.error("Failed to read config file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Write the current values back to the config file.
    private func save() {
        let configDir = configFilePath.deletingLastPathComponent()

        do {
            // Create the directory if it doesn't exist
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            var json: [String: Any] = [:]
            json["browser-engine"] = browserEngine.rawValue
            json["chromium-remote-debugging-port"] = chromiumRemoteDebuggingPort
            if cliInstallDismissed {
                json["cli-install-dismissed"] = cliInstallDismissed
            }

            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: configFilePath, options: .atomic)

            logger.info("Saved config to \(self.configFilePath.path, privacy: .public)")
        } catch {
            logger.error("Failed to write config file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
