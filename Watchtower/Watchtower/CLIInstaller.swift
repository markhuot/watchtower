import Foundation
import os

private let logger = Logger(subsystem: "com.watchtower", category: "CLIInstaller")

/// Utility for installing the Watchtower CLI binary into the user's PATH.
enum CLIInstaller {
    /// The default install location for the CLI symlink.
    static let installPath = "/usr/local/bin/watchtower"

    /// Path to the CLI binary bundled in the app.
    static var bundledBinaryPath: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("watchtower")
    }

    /// Whether the CLI is currently installed at the expected path.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installPath)
    }

    /// Whether the bundled CLI binary exists in the app bundle.
    static var isBundled: Bool {
        guard let path = bundledBinaryPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Whether we should prompt the user to install the CLI.
    static var shouldPrompt: Bool {
        !isInstalled && isBundled && !WatchtowerConfig.shared.cliInstallDismissed
    }

    /// Install the CLI by creating a symlink from /usr/local/bin/watchtower
    /// to the bundled binary in the app.
    static func install() throws {
        guard let bundledPath = bundledBinaryPath else {
            throw CLIInstallerError.binaryNotBundled
        }

        guard FileManager.default.fileExists(atPath: bundledPath.path) else {
            throw CLIInstallerError.binaryNotBundled
        }

        // First try without elevation
        do {
            try installSymlink(to: bundledPath.path)
            logger.info("CLI installed: \(self.installPath) -> \(bundledPath.path)")
            return
        } catch {
            logger.info("Direct install failed, attempting with privileges: \(error.localizedDescription)")
        }

        // Fall back to AppleScript for admin privileges
        let script = """
        do shell script "mkdir -p '\((installPath as NSString).deletingLastPathComponent)' && ln -sf '\(bundledPath.path)' '\(installPath)'" with administrator privileges
        """

        guard let appleScript = NSAppleScript(source: script) else {
            throw CLIInstallerError.scriptCreationFailed
        }

        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw CLIInstallerError.privilegedInstallFailed(message)
        }

        logger.info("CLI installed with privileges: \(self.installPath) -> \(bundledPath.path)")
    }

    private static func installSymlink(to target: String) throws {
        let fm = FileManager.default
        let installDir = (installPath as NSString).deletingLastPathComponent

        if !fm.fileExists(atPath: installDir) {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        }

        // Remove existing file/symlink
        if fm.fileExists(atPath: installPath) {
            try fm.removeItem(atPath: installPath)
        }

        try fm.createSymbolicLink(atPath: installPath, withDestinationPath: target)
    }
}

enum CLIInstallerError: LocalizedError {
    case binaryNotBundled
    case scriptCreationFailed
    case privilegedInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotBundled:
            return "The CLI binary was not found in the app bundle."
        case .scriptCreationFailed:
            return "Failed to create the installation script."
        case .privilegedInstallFailed(let message):
            return message
        }
    }
}
