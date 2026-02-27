import Foundation
import os

/// Lightweight Unix domain socket server for CLI → Watchtower IPC.
///
/// Listens on `~/.config/watchtower/watchtower.sock` and accepts
/// newline-delimited JSON commands.  Each command is dispatched to
/// the registered `PaneContainerViewModel` on the main queue.
///
/// Protocol:
///   → Client sends one JSON object, then shuts down the write end.
///   ← Server sends one JSON response object, then closes.
///
/// Command format (request):
///   { "command": "new-terminal", "paneId": "...", "directory": "/...", "shellCommand": "..." }
///   { "command": "new-browser",  "paneId": "...", "url": "https://...", "engine": "webkit|chromium", "remoteDebuggingPort": 9222 }
///   { "command": "close-pane",   "paneId": "..." }
///
/// Response format:
///   { "ok": true, "paneId": "..." }
///   { "ok": false, "error": "message" }
final class IPCServer {
    static let shared = IPCServer()

    private let logger = Logger(subsystem: "com.watchtower", category: "IPC")

    /// The Unix domain socket path.
    let socketPath: String = {
        let dir = NSHomeDirectory() + "/.config/watchtower"
        return dir + "/watchtower.sock"
    }()

    private var serverFD: Int32 = -1
    private var listenSource: DispatchSourceRead?

    /// Registered view models (one per window). Weak references so we don't
    /// prevent windows from being deallocated.
    private var viewModels: [WeakViewModel] = []

    private init() {}

    // MARK: - View Model Registry

    /// Register a view model (called by ContentView.onAppear).
    func register(_ viewModel: PaneContainerViewModel) {
        // Avoid duplicates
        viewModels.removeAll { $0.value == nil || $0.value === viewModel }
        viewModels.append(WeakViewModel(viewModel))
        logger.info("Registered view model, total: \(self.viewModels.count)")
    }

    /// Unregister a view model (called by ContentView.onDisappear).
    func unregister(_ viewModel: PaneContainerViewModel) {
        viewModels.removeAll { $0.value == nil || $0.value === viewModel }
        logger.info("Unregistered view model, total: \(self.viewModels.count)")
    }

    /// Find the view model that owns a pane with the given UUID.
    private func viewModel(forPaneId paneId: UUID) -> PaneContainerViewModel? {
        for weak in viewModels {
            guard let vm = weak.value else { continue }
            if vm.panes.contains(where: { $0.id == paneId }) {
                return vm
            }
        }
        return nil
    }

    /// Return any registered view model (first available).
    private func anyViewModel() -> PaneContainerViewModel? {
        viewModels.compactMap { $0.value }.first
    }

    // MARK: - Lifecycle

    func start() {
        // Ensure the directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Remove stale socket
        unlink(socketPath)

        // Create Unix domain socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { ptr in
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
                let pathBuf = rawBuf.baseAddress!.assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, pathSize - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverFD)
            serverFD = -1
            return
        }

        // Listen
        guard Darwin.listen(serverFD, 5) == 0 else {
            logger.error("Failed to listen on socket: \(errno)")
            close(serverFD)
            serverFD = -1
            return
        }

        // Set non-blocking
        var flags = fcntl(serverFD, F_GETFL)
        flags |= O_NONBLOCK
        fcntl(serverFD, F_SETFL, flags)

        // Dispatch source for accept
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        listenSource = source

        logger.info("IPC server listening on \(self.socketPath)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(serverFD, sockaddrPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Handle in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        // Set client socket to non-blocking
        var clientFlags = fcntl(fd, F_GETFL)
        clientFlags |= O_NONBLOCK
        fcntl(fd, F_SETFL, clientFlags)

        // Read until newline delimiter or timeout, up to 64KB.
        // Use poll() to wait for data since the client may send data
        // and shutdown in quick succession.
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000 // 5s

        outer: while DispatchTime.now().uptimeNanoseconds < deadline {
            let remaining = Int32((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
            let pollResult = poll(&pollFD, 1, min(remaining, 100))
            if pollResult < 0 { break } // error
            if pollResult == 0 { continue } // timeout on this poll, retry

            let n = read(fd, &buf, buf.count)
            if n > 0 {
                // Check for newline delimiter in the chunk
                for i in 0..<n {
                    if buf[i] == UInt8(ascii: "\n") {
                        data.append(contentsOf: buf[0..<i])
                        break outer
                    }
                }
                data.append(contentsOf: buf[0..<n])
                if data.count > 65536 { break }
            } else if n == 0 {
                // EOF — client closed write end
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                break // real error
            }
        }

        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(fd: fd, ["ok": false, "error": "Invalid JSON"])
            return
        }

        // Dispatch to main thread for UI operations
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any] = ["ok": false, "error": "No handler"]

        DispatchQueue.main.async { [weak self] in
            response = self?.handleCommand(json) ?? ["ok": false, "error": "Server shutdown"]
            semaphore.signal()
        }

        // Wait up to 5 seconds
        let result = semaphore.wait(timeout: .now() + 5)
        if result == .timedOut {
            response = ["ok": false, "error": "Timeout"]
        }

        sendResponse(fd: fd, response)
    }

    private func sendResponse(fd: Int32, _ response: [String: Any]) {
        if let responseData = try? JSONSerialization.data(withJSONObject: response),
           var responseStr = String(data: responseData, encoding: .utf8) {
            responseStr += "\n"
            responseStr.withCString { ptr in
                _ = write(fd, ptr, strlen(ptr))
            }
        }
    }

    // MARK: - Command Dispatch (called on main thread)

    private func handleCommand(_ json: [String: Any]) -> [String: Any] {
        guard let command = json["command"] as? String else {
            return ["ok": false, "error": "Missing 'command' field"]
        }

        // Resolve the target view model
        let vm: PaneContainerViewModel?
        if let paneIdStr = json["paneId"] as? String,
           let paneId = UUID(uuidString: paneIdStr) {
            vm = viewModel(forPaneId: paneId)
        } else {
            vm = anyViewModel()
        }

        guard let viewModel = vm else {
            return ["ok": false, "error": "No Watchtower window found"]
        }

        switch command {
        case "new-terminal":
            return handleNewTerminal(json, viewModel: viewModel)
        case "new-browser":
            return handleNewBrowser(json, viewModel: viewModel)
        case "close-pane":
            return handleClosePane(json, viewModel: viewModel)
        default:
            return ["ok": false, "error": "Unknown command: \(command)"]
        }
    }

    private func handleNewTerminal(_ json: [String: Any], viewModel: PaneContainerViewModel) -> [String: Any] {
        // If a paneId was provided, temporarily focus that pane so the new
        // terminal opens adjacent to it.
        if let paneIdStr = json["paneId"] as? String,
           let paneId = UUID(uuidString: paneIdStr),
           let sourcePaneIndex = viewModel.panes.firstIndex(where: { $0.id == paneId }) {
            viewModel.focusPane(viewModel.panes[sourcePaneIndex])
        }

        let directory = json["directory"] as? String
        let shellCommand = json["shellCommand"] as? String

        let terminal = viewModel.addTerminal(directory: directory, initialInput: shellCommand)
        viewModel.focusPane(terminal)
        return ["ok": true, "paneId": terminal.id.uuidString]
    }

    private func handleNewBrowser(_ json: [String: Any], viewModel: PaneContainerViewModel) -> [String: Any] {
        // If a paneId was provided, temporarily focus that pane so the new
        // browser opens adjacent to it.
        if let paneIdStr = json["paneId"] as? String,
           let paneId = UUID(uuidString: paneIdStr),
           let sourcePaneIndex = viewModel.panes.firstIndex(where: { $0.id == paneId }) {
            viewModel.focusPane(viewModel.panes[sourcePaneIndex])
        }

        let urlString = json["url"] as? String ?? "about:blank"
        let url = URL(string: urlString) ?? URL(string: "about:blank")!
        let engine: BrowserEngine?
        if let engineStr = json["engine"] as? String {
            engine = BrowserEngine(rawValue: engineStr)
        } else {
            engine = nil
        }

        // Handle remote debugging port — must be set before CEF initializes
        var warning: String? = nil
        if let port = json["remoteDebuggingPort"] as? Int, port > 0 {
            if ChromiumManager.shared.isInitialized {
                let currentPort = ChromiumManager.shared.initializedRemoteDebuggingPort
                if currentPort != port {
                    warning = "CEF is already initialized with remote debugging port \(currentPort). Cannot change to \(port). Using existing port."
                }
                // If same port, no warning needed — it's already active
            } else {
                // CEF not yet initialized — set the port so it picks it up on init
                WatchtowerConfig.shared.chromiumRemoteDebuggingPort = port
            }
        }

        let browser = viewModel.addBrowser(url: url, engine: engine)
        viewModel.focusPane(browser)

        var response: [String: Any] = ["ok": true, "paneId": browser.id.uuidString]
        if let warning = warning {
            response["warning"] = warning
        }
        return response
    }

    private func handleClosePane(_ json: [String: Any], viewModel: PaneContainerViewModel) -> [String: Any] {
        guard let paneIdStr = json["paneId"] as? String,
              let paneId = UUID(uuidString: paneIdStr) else {
            return ["ok": false, "error": "Missing or invalid 'paneId' field"]
        }

        guard viewModel.panes.contains(where: { $0.id == paneId }) else {
            return ["ok": false, "error": "Pane not found: \(paneIdStr)"]
        }

        viewModel.removePane(byId: paneId)
        return ["ok": true]
    }
}

// MARK: - WeakViewModel

private struct WeakViewModel {
    weak var value: PaneContainerViewModel?
    init(_ value: PaneContainerViewModel) {
        self.value = value
    }
}
