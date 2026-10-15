import Foundation
import Darwin

/// Unix domain socket listener. Hands accepted client fds to the broker.
public final class SocketServer {
    public let path: String
    public var onAccept: ((Int32) -> Void)?

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue: DispatchQueue

    public init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    public func start() throws {
        // If another broker is already listening on this path, refuse to start.
        // Otherwise the unlink() below would steal the socket from the live instance.
        if isAnotherBrokerListening(path: path) {
            throw NSError(domain: "WatchtowerBroker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "another broker is already listening on \(path)"])
        }

        // Remove stale socket file (no listener answered).
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw POSIXError(.init(rawValue: errno)!) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
            close(fd)
            throw NSError(domain: "WatchtowerBroker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(path)"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                for (i, b) in pathBytes.enumerated() {
                    cptr[i] = CChar(bitPattern: b)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        if bindRes < 0 {
            let e = errno
            close(fd)
            throw POSIXError(.init(rawValue: e)!)
        }

        // Restrict to user only.
        chmod(path, 0o600)

        if listen(fd, 64) < 0 {
            let e = errno
            close(fd)
            throw POSIXError(.init(rawValue: e)!)
        }

        // Non-blocking accept loop via DispatchSourceRead.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailable()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        listenFd = fd
        acceptSource = source
        source.resume()

        Log.info("listening on \(path)")
    }

    private func acceptAvailable() {
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFd, sa, &len)
                }
            }
            if client < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
                Log.warn("accept failed: \(String(cString: strerror(e)))")
                return
            }

            // Non-blocking client fd.
            let cflags = fcntl(client, F_GETFL, 0)
            if cflags >= 0 {
                _ = fcntl(client, F_SETFL, cflags | O_NONBLOCK)
            }

            onAccept?(client)
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFd = -1
        unlink(path)
    }
}

/// Probe a Unix socket path: returns true iff a process is currently accept()'ing on it.
/// (A connect() that succeeds proves a listener is alive — even if there's a stale .sock
/// file from a previous run, no one will be listening, and connect will fail with ECONNREFUSED
/// or ENOENT.)
public func isAnotherBrokerListening(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8) + [0]
    if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) { return false }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
            for (i, b) in pathBytes.enumerated() {
                cptr[i] = CChar(bitPattern: b)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, len)
        }
    }
    return result == 0
}
