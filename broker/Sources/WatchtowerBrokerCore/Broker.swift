import Foundation
import Darwin

public final class Broker {
    public struct Config {
        public var bufferCapacity: Int = 1 * 1024 * 1024  // 1 MiB per pane
        public var defaultShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        public var brokerVersion: String = "0.1.0"
        public init() {}
    }

    public let config: Config
    public let queue = DispatchQueue(label: "watchtower.broker.main")
    private let server: SocketServer
    private var panes: [UUID: PTYSession] = [:]
    private var clients: [UUID: ClientConnection] = [:]
    private let serverId = UUID().uuidString

    public init(config: Config = Config()) throws {
        try BrokerPaths.ensureDirectories()
        self.config = config
        self.server = SocketServer(path: BrokerPaths.socketURL.path, queue: queue)
    }

    public func start() throws {
        server.onAccept = { [weak self] fd in
            self?.handleAccept(fd)
        }
        try server.start()
        writePidFile()
        Log.info("broker \(config.brokerVersion) up; pid=\(getpid()) socket=\(BrokerPaths.socketURL.path)")
    }

    public func stop() {
        // Best-effort: persist scrollback for all panes, terminate, close clients.
        for pane in panes.values {
            pane.persistScrollback()
            pane.terminate()
        }
        for c in clients.values {
            c.closeConnection()
        }
        server.stop()
        unlink(BrokerPaths.pidFileURL.path)
    }

    private func writePidFile() {
        let pid = String(getpid())
        try? pid.write(to: BrokerPaths.pidFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Client lifecycle

    private func handleAccept(_ fd: Int32) {
        let conn = ClientConnection(fd: fd, queue: queue)
        clients[conn.id] = conn
        conn.onFrame = { [weak self, weak conn] frame in
            guard let self, let conn else { return }
            self.handleFrame(frame, from: conn)
        }
        conn.onClose = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.clients[conn.id] = nil
            Log.debug("client \(conn.id) disconnected (\(self.clients.count) remain)")
        }
        conn.start()
        Log.debug("client \(conn.id) connected (\(clients.count) total)")

        // Send WELCOME proactively.
        let welcome = WelcomeMessage(brokerVersion: config.brokerVersion, serverId: serverId)
        if let frame = try? WireCoder.encode(welcome, type: .welcome) {
            conn.send(frame)
        }
    }

    // MARK: - Frame routing

    private func handleFrame(_ frame: Frame, from client: ClientConnection) {
        switch frame.type {
        case .hello:
            if let m = try? WireCoder.decode(frame, as: HelloMessage.self) {
                Log.debug("client \(client.id) hello: \(m.client) v\(m.version)")
            }

        case .listPanes:
            sendPaneList(to: client)

        case .openPane:
            guard let m = try? WireCoder.decode(frame, as: OpenPaneMessage.self) else {
                sendError(to: client, code: "bad_request", message: "invalid OPEN_PANE payload")
                return
            }
            do {
                let pane = try openPane(m)
                let opened = OpenedMessage(paneId: pane.id.uuidString)
                if let f = try? WireCoder.encode(opened, type: .opened) {
                    client.send(f)
                }
            } catch {
                sendError(to: client, code: "spawn_failed", message: "\(error)")
            }

        case .attach:
            guard let m = try? WireCoder.decode(frame, as: AttachMessage.self),
                  let id = UUID(uuidString: m.paneId),
                  let pane = panes[id] else {
                sendError(to: client, code: "no_such_pane", message: "unknown pane id")
                return
            }
            client.attachedPanes.insert(id)
            // Confirm attach.
            let ack = AttachedMessage(paneId: pane.id.uuidString, cols: pane.cols, rows: pane.rows)
            if let f = try? WireCoder.encode(ack, type: .attached) {
                client.send(f)
            }
            // Replay scrollback.
            if m.replayScrollback {
                let snap = pane.buffer.snapshot()
                if !snap.isEmpty {
                    let f = WireCoder.dataFrame(type: .scrollback, paneId: pane.id, bytes: Data(snap))
                    client.send(f)
                }
            }

        case .detach:
            if let m = try? WireCoder.decode(frame, as: DetachMessage.self),
               let id = UUID(uuidString: m.paneId) {
                client.attachedPanes.remove(id)
            }

        case .closePane:
            if let m = try? WireCoder.decode(frame, as: ClosePaneMessage.self),
               let id = UUID(uuidString: m.paneId),
               let pane = panes[id] {
                pane.terminate()
            }

        case .resize:
            if let m = try? WireCoder.decode(frame, as: ResizeMessage.self),
               let id = UUID(uuidString: m.paneId),
               let pane = panes[id] {
                pane.resize(cols: m.cols, rows: m.rows)
            }

        case .input:
            guard let (paneId, body) = WireCoder.splitDataFrame(frame),
                  let pane = panes[paneId] else { return }
            pane.write(body)

        case .welcome, .panes, .opened, .attached, .paneExited, .errorMsg,
             .output, .scrollback:
            // Server→client only; ignore on inbound.
            Log.debug("client \(client.id) sent unexpected server-only frame: \(frame.type)")
        }
    }

    private func sendPaneList(to client: ClientConnection) {
        let summaries = panes.values.map {
            PaneSummary(id: $0.id.uuidString, title: $0.title,
                        cols: $0.cols, rows: $0.rows, alive: $0.alive)
        }
        let msg = PanesMessage(panes: Array(summaries))
        if let f = try? WireCoder.encode(msg, type: .panes) {
            client.send(f)
        }
    }

    private func sendError(to client: ClientConnection, code: String, message: String) {
        let err = ErrorMessage(code: code, message: message)
        if let f = try? WireCoder.encode(err, type: .errorMsg) {
            client.send(f)
        }
    }

    // MARK: - Pane lifecycle

    private func openPane(_ req: OpenPaneMessage) throws -> PTYSession {
        let id = UUID()
        let cmd: [String]
        if let c = req.command, !c.isEmpty {
            cmd = c
        } else {
            cmd = [config.defaultShell, "-l"]
        }

        // Compose env: pass through what the broker has, override with what the request asked
        // for, and inject WATCHTOWER_PANE_ID so CLI tools inside the pane know who they are.
        var env = ProcessInfo.processInfo.environment
        if let reqEnv = req.env {
            for (k, v) in reqEnv { env[k] = v }
        }
        env["WATCHTOWER_PANE_ID"] = id.uuidString

        let spawn = try spawnPTY(PTYSpawnRequest(
            cwd: req.cwd,
            command: cmd,
            env: env,
            cols: req.cols,
            rows: req.rows
        ))

        let pane = PTYSession(
            id: id,
            title: req.title ?? cmd.first ?? "shell",
            cols: req.cols,
            rows: req.rows,
            masterFd: spawn.masterFd,
            pid: spawn.pid,
            bufferCapacity: config.bufferCapacity,
            scrollbackURL: BrokerPaths.scrollbackURL(paneId: id),
            queue: queue
        )

        pane.onOutput = { [weak self, weak pane] data in
            guard let self, let pane else { return }
            self.fanoutOutput(paneId: pane.id, data: data)
        }
        pane.onExited = { [weak self, weak pane] code in
            guard let self, let pane else { return }
            Log.info("pane \(pane.id) exited code=\(code)")
            self.broadcastPaneExited(paneId: pane.id, exitCode: code)
            self.panes[pane.id] = nil
        }

        panes[id] = pane
        pane.start()
        Log.info("opened pane \(id) cmd=\(cmd) cols=\(req.cols) rows=\(req.rows)")
        return pane
    }

    private func fanoutOutput(paneId: UUID, data: Data) {
        let frame = WireCoder.dataFrame(type: .output, paneId: paneId, bytes: data)
        for client in clients.values where client.attachedPanes.contains(paneId) {
            client.send(frame)
        }
    }

    private func broadcastPaneExited(paneId: UUID, exitCode: Int32) {
        let msg = PaneExitedMessage(paneId: paneId.uuidString, exitCode: exitCode)
        guard let frame = try? WireCoder.encode(msg, type: .paneExited) else { return }
        for client in clients.values where client.attachedPanes.contains(paneId) {
            client.send(frame)
            client.attachedPanes.remove(paneId)
        }
    }

    // MARK: - Restore scrollback for previously-known panes

    /// Inspect the scrollback directory for any persisted pane logs and, if found,
    /// register them as orphaned scrollback that future ATTACHes can replay against.
    /// We do not respawn the shell — that would require launchd-managed broker lifecycle.
    public func loadOrphanedScrollback() {
        let dir = BrokerPaths.scrollbackDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".log") {
            let idStr = String(name.dropLast(4))
            guard let id = UUID(uuidString: idStr) else { continue }
            let url = dir.appendingPathComponent(name)
            // We don't have a live PTY for these; create a "ghost" pane entry that a client
            // can ATTACH to (read-only). For Phase 1, ATTACH on a ghost replays scrollback;
            // INPUT is silently dropped because the master fd is -1.
            let ghost = PTYSession(
                id: id,
                title: "(detached)",
                cols: 80,
                rows: 24,
                masterFd: -1,
                pid: 0,
                bufferCapacity: config.bufferCapacity,
                scrollbackURL: url,
                queue: queue
            )
            ghost.loadScrollback()
            ghost.markDead()
            panes[id] = ghost
            Log.info("registered ghost pane \(id) from \(url.lastPathComponent)")
        }
    }
}
