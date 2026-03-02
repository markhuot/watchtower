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

    static func shouldPrompt(dismissed: Bool) -> Bool {
        switch status() {
        case .installedOutdated:
            return true
        case .notInstalled:
            return !dismissed
        default:
            return false
        }
    }

    static func status() -> CLIInstallState {
        if !isBundled {
            return .notBundled
        }

        let bundledVersion = bundledVersion()

        if !isInstalled {
            return .notInstalled(bundledVersion: bundledVersion)
        }

        let installedVersion = installedVersion()

        guard
            let bundledVersion,
            let installedVersion,
            let comparison = compareVersions(installedVersion, bundledVersion)
        else {
            return .installedCurrent(version: installedVersion)
        }

        if comparison == 0 {
            return .installedCurrent(version: installedVersion)
        } else if comparison < 0 {
            return .installedOutdated(installed: installedVersion, bundled: bundledVersion)
        } else {
            return .installedNewer(installed: installedVersion, bundled: bundledVersion)
        }
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

    static func bundledVersion() -> String? {
        guard let bundledPath = bundledBinaryPath else { return nil }
        return readVersion(at: bundledPath.path)
    }

    static func installedVersion() -> String? {
        guard isInstalled else { return nil }
        return readVersion(at: installPath)
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

    private static func readVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            logger.info("Failed to run CLI for version: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            logger.info("CLI version command failed with code \(process.terminationStatus)")
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return extractVersion(from: output)
    }

    private static func extractVersion(from output: String) -> String? {
        let pattern = #"\b\d+\.\d+\.\d+\b"#
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

        guard lhsParts.count == 3, rhsParts.count == 3 else { return nil }

        for index in 0..<3 {
            if lhsParts[index] != rhsParts[index] {
                return lhsParts[index] < rhsParts[index] ? -1 : 1
            }
        }

        return 0
    }
}

enum CLIInstallState: Equatable {
    case notBundled
    case notInstalled(bundledVersion: String?)
    case installedCurrent(version: String?)
    case installedOutdated(installed: String?, bundled: String?)
    case installedNewer(installed: String?, bundled: String?)
    case error(String)
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
