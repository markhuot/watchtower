import Foundation
import os

/// Locates the bundled `watchtower-broker` binary, ensures a single broker
/// is running, and exposes the socket path it listens on.
///
/// This is intentionally minimal: it spawns and supervises the broker process
/// but does not yet route panes through it. The pane-spawn integration is a
/// separate decision (see ghostty PTY-ownership constraint) tracked in memory.
@MainActor
final class BrokerSupervisor {
    static let shared = BrokerSupervisor()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "BrokerSupervisor"
    )

    private var process: Process?
    private(set) var socketURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Watchtower/broker.sock")
    }()

    /// Locate the bundled broker binary inside the app's Resources.
    static var bundledBrokerURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("watchtower-broker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private init() {}

    /// Spawn the broker if it isn't already running. Idempotent: detects an
    /// already-listening broker by probing the socket and skips the spawn.
    func startIfNeeded() {
        if let p = process, p.isRunning { return }
        if probeSocketAlive() {
            Self.logger.info("broker already running on socket; skipping spawn")
            return
        }
        guard let binary = Self.bundledBrokerURL else {
            Self.logger.warning("watchtower-broker binary not found in bundle Resources")
            return
        }

        let p = Process()
        p.executableURL = binary
        p.arguments = []
        p.terminationHandler = { [weak self] proc in
            Self.logger.info("broker exited status=\(proc.terminationStatus, privacy: .public)")
            DispatchQueue.main.async { self?.process = nil }
        }

        do {
            try p.run()
            process = p
            Self.logger.info("broker started pid=\(p.processIdentifier, privacy: .public)")
        } catch {
            Self.logger.error("failed to start broker: \(String(describing: error), privacy: .public)")
        }
    }

    /// Try connecting to the broker socket; returns true if something is accepting.
    private func probeSocketAlive() -> Bool {
        let path = socketURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        if bytes.count > MemoryLayout.size(ofValue: addr.sun_path) { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        return r == 0
    }

    /// Stop the broker (best-effort SIGTERM). Called on app shutdown.
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
    }
}
