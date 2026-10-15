import Foundation
import WatchtowerBrokerCore
import Darwin

// Minimal client: `watchtower-broker-cli open|list|attach|kill ...`
//
//   open [-- <command>...]   # open a new pane and attach; replays stdin/stdout
//   list                     # list panes (alive + ghosts)
//   attach <pane-id>         # attach to existing pane (replay scrollback)
//   kill <pane-id>           # send CLOSE_PANE
//
// This is a development/test client — it puts the local TTY into raw mode,
// shuttles bytes between stdin and the broker socket, and prints OUTPUT
// frames to stdout. It exists to validate the broker before the macOS app
// is wired up.

func usage() -> Never {
    let s = """
    watchtower-broker-cli <command>

    Commands:
      open [-- <argv>...]    open a new pane (default: $SHELL -l) and attach
      list                   list current panes
      attach <pane-id>       attach to an existing pane and stream
      kill <pane-id>         send CLOSE_PANE for a pane
    Options:
      --root <dir>           override the broker support directory
    """
    FileHandle.standardError.write(Data(s.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(2)
}

var rawArgs = CommandLine.arguments.dropFirst()
var argv: [String] = []
var rootOverride: String?

var iter = rawArgs.makeIterator()
while let a = iter.next() {
    if a == "--root" {
        rootOverride = iter.next()
    } else {
        argv.append(a)
        // Once we hit the subcommand, gobble the remainder verbatim
        // so `open -- bash -i` works.
        argv.append(contentsOf: iter)
        break
    }
}

if let path = rootOverride {
    BrokerPaths.rootOverride = URL(fileURLWithPath: path, isDirectory: true)
}

guard let cmd = argv.first else { usage() }
let restArgs = Array(argv.dropFirst())

// MARK: - Connection

final class Connection {
    let fd: Int32
    private let parser = FrameParser()
    var onFrame: ((Frame) -> Void)?

    init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw POSIXError(.init(rawValue: errno)!) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
            throw NSError(domain: "client", code: 1)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                for (i, b) in pathBytes.enumerated() {
                    cptr[i] = CChar(bitPattern: b)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        if r < 0 {
            let e = errno
            close(fd)
            throw POSIXError(.init(rawValue: e)!)
        }
    }

    func send(_ frame: Frame) {
        let data = frame.encode()
        var written = 0
        data.withUnsafeBytes { rb in
            guard let base = rb.baseAddress else { return }
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    /// Blocking read; pumps frames into onFrame until EOF.
    func runReadLoop() {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                parser.feed(Data(buf.prefix(n)))
                do {
                    while let frame = try parser.nextFrame() {
                        onFrame?(frame)
                    }
                } catch {
                    fputs("frame error: \(error)\n", stderr)
                    return
                }
            } else if n == 0 {
                return
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                fputs("read error: \(String(cString: strerror(errno)))\n", stderr)
                return
            }
        }
    }
}

func helloFrame(_ name: String) -> Frame {
    let m = HelloMessage(client: name)
    return try! WireCoder.encode(m, type: .hello)
}

func waitWelcome(_ conn: Connection) {
    let semaphore = DispatchSemaphore(value: 0)
    var got = false
    conn.onFrame = { f in
        if f.type == .welcome { got = true; semaphore.signal() }
    }
    DispatchQueue.global().async {
        conn.runReadLoop()
    }
    if semaphore.wait(timeout: .now() + 2) == .timedOut {
        fputs("timed out waiting for WELCOME\n", stderr)
        exit(1)
    }
    _ = got
}

// MARK: - Subcommands

func cmdList() {
    let conn = try! Connection(socketPath: BrokerPaths.socketURL.path)
    let parser = FrameParser()
    conn.send(helloFrame("cli"))
    conn.send(Frame(type: .listPanes, payload: Data()))
    _ = parser

    var done = false
    let sema = DispatchSemaphore(value: 0)
    conn.onFrame = { f in
        switch f.type {
        case .welcome:
            return
        case .panes:
            if let m = try? WireCoder.decode(f, as: PanesMessage.self) {
                if m.panes.isEmpty {
                    print("(no panes)")
                } else {
                    for p in m.panes {
                        print("\(p.id)  alive=\(p.alive)  cols=\(p.cols) rows=\(p.rows)  \(p.title)")
                    }
                }
            }
            done = true
            sema.signal()
        case .errorMsg:
            if let m = try? WireCoder.decode(f, as: ErrorMessage.self) {
                fputs("error: \(m.code): \(m.message)\n", stderr)
            }
            done = true
            sema.signal()
        default:
            return
        }
    }
    DispatchQueue.global().async { conn.runReadLoop() }
    _ = sema.wait(timeout: .now() + 5)
    _ = done
}

func cmdKill(_ id: String) {
    guard UUID(uuidString: id) != nil else {
        fputs("invalid pane id\n", stderr)
        exit(2)
    }
    let conn = try! Connection(socketPath: BrokerPaths.socketURL.path)
    conn.send(helloFrame("cli"))
    let m = ClosePaneMessage(paneId: id)
    if let f = try? WireCoder.encode(m, type: .closePane) {
        conn.send(f)
    }
    // Give the broker a moment to act.
    Thread.sleep(forTimeInterval: 0.2)
}

// Get current terminal cols/rows, or sane defaults.
func currentWinsize() -> (UInt16, UInt16) {
    var ws = winsize()
    if ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
        return (ws.ws_col, ws.ws_row)
    }
    return (80, 24)
}

// Put stdin into raw mode; return original termios for restore.
func makeRaw(_ fd: Int32) -> termios? {
    var orig = termios()
    if tcgetattr(fd, &orig) != 0 { return nil }
    var raw = orig
    cfmakeraw(&raw)
    if tcsetattr(fd, TCSANOW, &raw) != 0 { return nil }
    return orig
}

func restore(_ fd: Int32, _ orig: termios) {
    var t = orig
    _ = tcsetattr(fd, TCSANOW, &t)
}

func runAttachLoop(conn: Connection, paneId: UUID) {
    // Put stdin in raw mode.
    let stdinIsTTY = isatty(STDIN_FILENO) != 0
    var savedTermios: termios? = nil
    if stdinIsTTY {
        savedTermios = makeRaw(STDIN_FILENO)
    }
    defer {
        if let s = savedTermios { restore(STDIN_FILENO, s) }
    }

    // Forward SIGWINCH.
    let sigwinchSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    sigwinchSrc.setEventHandler {
        let (c, r) = currentWinsize()
        let m = ResizeMessage(paneId: paneId.uuidString, cols: c, rows: r)
        if let f = try? WireCoder.encode(m, type: .resize) {
            conn.send(f)
        }
    }
    sigwinchSrc.resume()
    signal(SIGWINCH, SIG_IGN)

    let exitSema = DispatchSemaphore(value: 0)

    // Reader: broker → stdout.
    conn.onFrame = { f in
        switch f.type {
        case .output, .scrollback:
            if let (_, body) = WireCoder.splitDataFrame(f) {
                _ = body.withUnsafeBytes { rb -> Int in
                    guard let base = rb.baseAddress else { return 0 }
                    return Darwin.write(STDOUT_FILENO, base, body.count)
                }
            }
        case .paneExited:
            if let m = try? WireCoder.decode(f, as: PaneExitedMessage.self) {
                fputs("\r\n[pane exited code=\(m.exitCode)]\r\n", stderr)
            }
            exitSema.signal()
        case .errorMsg:
            if let m = try? WireCoder.decode(f, as: ErrorMessage.self) {
                fputs("\r\nerror: \(m.code): \(m.message)\r\n", stderr)
            }
        case .welcome, .attached:
            return
        default:
            return
        }
    }
    DispatchQueue.global().async {
        conn.runReadLoop()
        exitSema.signal()
    }

    // Writer: stdin → broker as INPUT frames.
    DispatchQueue.global().async {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(STDIN_FILENO, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                let frame = WireCoder.dataFrame(
                    type: .input,
                    paneId: paneId,
                    bytes: Data(buf.prefix(n))
                )
                conn.send(frame)
            } else if n == 0 {
                return
            } else {
                if errno == EINTR { continue }
                return
            }
        }
    }

    exitSema.wait()
}

func cmdAttach(_ id: String) {
    guard let pid = UUID(uuidString: id) else {
        fputs("invalid pane id\n", stderr)
        exit(2)
    }
    let conn = try! Connection(socketPath: BrokerPaths.socketURL.path)
    conn.send(helloFrame("cli"))

    let attach = AttachMessage(paneId: id, replayScrollback: true)
    if let f = try? WireCoder.encode(attach, type: .attach) {
        conn.send(f)
    }
    let (c, r) = currentWinsize()
    if let f = try? WireCoder.encode(ResizeMessage(paneId: id, cols: c, rows: r), type: .resize) {
        conn.send(f)
    }

    runAttachLoop(conn: conn, paneId: pid)
}

func cmdOpen(_ argv: [String]) {
    let conn = try! Connection(socketPath: BrokerPaths.socketURL.path)
    conn.send(helloFrame("cli"))

    let cwd = FileManager.default.currentDirectoryPath
    let (cols, rows) = currentWinsize()
    let cmd: [String]? = argv.isEmpty ? nil : argv
    let req = OpenPaneMessage(cwd: cwd, command: cmd, env: nil,
                              cols: cols, rows: rows,
                              title: cmd?.first)
    if let f = try? WireCoder.encode(req, type: .openPane) {
        conn.send(f)
    }

    // Wait for OPENED, then send ATTACH inline.
    let sem = DispatchSemaphore(value: 0)
    var paneId: UUID?
    conn.onFrame = { f in
        switch f.type {
        case .opened:
            if let m = try? WireCoder.decode(f, as: OpenedMessage.self),
               let id = UUID(uuidString: m.paneId) {
                paneId = id
                sem.signal()
            }
        case .errorMsg:
            if let m = try? WireCoder.decode(f, as: ErrorMessage.self) {
                fputs("error: \(m.code): \(m.message)\n", stderr)
            }
            sem.signal()
        case .welcome:
            return
        default:
            return
        }
    }
    DispatchQueue.global().async { conn.runReadLoop() }
    _ = sem.wait(timeout: .now() + 5)

    guard let id = paneId else {
        fputs("failed to open pane\n", stderr)
        exit(1)
    }

    let attach = AttachMessage(paneId: id.uuidString, replayScrollback: false)
    if let f = try? WireCoder.encode(attach, type: .attach) {
        conn.send(f)
    }
    runAttachLoop(conn: conn, paneId: id)
}

// MARK: - Dispatch

switch cmd {
case "list":
    cmdList()
case "open":
    // strip leading "--" if present
    var rest = restArgs
    if rest.first == "--" { rest.removeFirst() }
    cmdOpen(rest)
case "attach":
    guard let id = restArgs.first else { usage() }
    cmdAttach(id)
case "kill":
    guard let id = restArgs.first else { usage() }
    cmdKill(id)
default:
    usage()
}
