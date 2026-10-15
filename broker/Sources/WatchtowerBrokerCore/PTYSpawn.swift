import Foundation
import Darwin

public struct PTYSpawnRequest {
    public var cwd: String?
    public var command: [String]
    public var env: [String: String]
    public var cols: UInt16
    public var rows: UInt16

    public init(cwd: String? = nil,
                command: [String],
                env: [String: String] = [:],
                cols: UInt16,
                rows: UInt16) {
        self.cwd = cwd
        self.command = command
        self.env = env
        self.cols = cols
        self.rows = rows
    }
}

public struct PTYSpawnResult {
    public let masterFd: Int32
    public let pid: pid_t
}

public enum PTYSpawnError: Error, CustomStringConvertible {
    case forkptyFailed(Int32)
    case execFailed(Int32)
    case emptyCommand
    case ioctlFailed(Int32)

    public var description: String {
        switch self {
        case .forkptyFailed(let e): return "forkpty failed: \(String(cString: strerror(e)))"
        case .execFailed(let e): return "execve failed: \(String(cString: strerror(e)))"
        case .emptyCommand: return "command must be non-empty"
        case .ioctlFailed(let e): return "ioctl failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Spawn a child process attached to a PTY. Returns the master fd in the parent.
/// The child has cwd, env, and TIOCSCTTY set up.
public func spawnPTY(_ request: PTYSpawnRequest) throws -> PTYSpawnResult {
    guard !request.command.isEmpty else { throw PTYSpawnError.emptyCommand }

    var winsize = winsize(ws_row: request.rows, ws_col: request.cols, ws_xpixel: 0, ws_ypixel: 0)
    var master: Int32 = -1

    // forkpty allocates a PTY pair, forks, makes the slave the controlling terminal in the
    // child, dups it to 0/1/2, closes the master in the child. Parent gets the master fd.
    let pid = forkpty(&master, nil, nil, &winsize)
    if pid < 0 {
        throw PTYSpawnError.forkptyFailed(errno)
    }

    if pid == 0 {
        // Child process. Replace image with the requested command.
        // Set cwd if requested.
        if let cwd = request.cwd, !cwd.isEmpty {
            _ = chdir(cwd)
        }

        // Build argv (null-terminated).
        let argvPointers: [UnsafeMutablePointer<CChar>?] =
            request.command.map { strdup($0) } + [nil]

        // Build envp from the requested env. We don't inherit; broker is responsible for
        // passing through any vars it wants the child to see (including TERM, PATH, HOME).
        // Provide sensible defaults if missing.
        var envDict = request.env
        if envDict["TERM"] == nil { envDict["TERM"] = "xterm-256color" }
        if envDict["PATH"] == nil { envDict["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if envDict["SHELL"] == nil, let shell = ProcessInfo.processInfo.environment["SHELL"] {
            envDict["SHELL"] = shell
        }
        if envDict["HOME"] == nil, let home = ProcessInfo.processInfo.environment["HOME"] {
            envDict["HOME"] = home
        }

        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let envPointers: [UnsafeMutablePointer<CChar>?] =
            envStrings.map { strdup($0) } + [nil]

        // execve searches based on absolute path, or PATH if it contains a slash. We use
        // execvp via the explicit env: there's no execvpe on macOS, so we set env with
        // setenv first and call execvp.
        for (k, v) in envDict {
            setenv(k, v, 1)
        }
        // Suppress unused-variable warning on envPointers; we don't actually need to keep
        // them around since we used setenv.
        _ = envPointers

        argvPointers.withUnsafeBufferPointer { argvBuf in
            _ = execvp(argvBuf[0], argvBuf.baseAddress!)
        }
        // execvp returned — error.
        let err = errno
        _ = write(2, "execvp failed: ", 15)
        let msg = String(cString: strerror(err))
        msg.withCString { _ = write(2, $0, strlen($0)) }
        _ = write(2, "\n", 1)
        _exit(127)
    }

    // Parent: master fd is good. Set non-blocking so reads in the dispatch source don't
    // hang if there's a partial read.
    let flags = fcntl(master, F_GETFL, 0)
    if flags >= 0 {
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
    }

    return PTYSpawnResult(masterFd: master, pid: pid)
}

public func setPTYWindowSize(masterFd: Int32, cols: UInt16, rows: UInt16) {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(masterFd, TIOCSWINSZ, &ws)
}
