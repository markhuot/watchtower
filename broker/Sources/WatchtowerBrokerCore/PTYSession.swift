import Foundation
import Darwin

/// One running pane: PTY master fd, child pid, ring buffer, attached client list.
/// All state mutation happens on the broker's serial queue (passed in at construction).
public final class PTYSession {
    public let id: UUID
    public var title: String
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16
    public internal(set) var alive: Bool = true
    public let masterFd: Int32
    public let pid: pid_t
    public let buffer: RingBuffer

    public func markDead() { alive = false }

    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    public var onOutput: ((Data) -> Void)?
    public var onExited: ((Int32) -> Void)?

    private let scrollbackURL: URL?

    public init(id: UUID,
                title: String,
                cols: UInt16,
                rows: UInt16,
                masterFd: Int32,
                pid: pid_t,
                bufferCapacity: Int,
                scrollbackURL: URL?,
                queue: DispatchQueue) {
        self.id = id
        self.title = title
        self.cols = cols
        self.rows = rows
        self.masterFd = masterFd
        self.pid = pid
        self.buffer = RingBuffer(capacity: bufferCapacity)
        self.scrollbackURL = scrollbackURL
        self.queue = queue
    }

    /// Begin reading from the master fd. Bytes go into ring buffer + onOutput callback.
    /// Caller must invoke this once after construction.
    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [masterFd] in
            close(masterFd)
        }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            return read(masterFd, ptr.baseAddress, ptr.count)
        }
        if n > 0 {
            let slice = buf.prefix(n)
            buffer.append(slice)
            let data = Data(slice)
            onOutput?(data)
        } else if n == 0 {
            // EOF — child closed its end.
            handleExit()
        } else {
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                return
            }
            // EIO on macOS PTY usually means slave disconnected.
            Log.debug("pane \(id) read error: \(String(cString: strerror(err)))")
            handleExit()
        }
    }

    private var exitHandled = false
    private func handleExit() {
        guard !exitHandled else { return }
        exitHandled = true

        readSource?.cancel()
        readSource = nil

        // Reap the child to get its exit status. waitpid is blocking with 0 flags;
        // use WNOHANG and a brief retry, since the child may not be reaped yet.
        var status: Int32 = 0
        var exitCode: Int32 = -1
        for _ in 0..<10 {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                if (status & 0x7f) == 0 {
                    exitCode = (status >> 8) & 0xff
                } else {
                    exitCode = 128 + (status & 0x7f)
                }
                break
            }
            if r == 0 {
                usleep(10_000)
                continue
            }
            break
        }

        alive = false
        persistScrollback()
        onExited?(exitCode)
    }

    public func write(_ data: Data) {
        guard alive else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(masterFd,
                                     base.advanced(by: offset),
                                     remaining)
                if n > 0 {
                    offset += n
                    remaining -= n
                } else if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // Master fd is non-blocking. Backpressure: drop the rest.
                        // (A future iteration could buffer and retry on writability.)
                        Log.warn("pane \(id) write would block; dropped \(remaining) bytes")
                        return
                    }
                    Log.warn("pane \(id) write error: \(String(cString: strerror(err)))")
                    return
                } else {
                    return
                }
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        setPTYWindowSize(masterFd: masterFd, cols: cols, rows: rows)
    }

    /// Kill the child (SIGTERM, then SIGKILL after grace period).
    public func terminate() {
        guard alive, pid > 0 else { return }
        kill(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.alive, self.pid > 0 else { return }
            kill(self.pid, SIGKILL)
        }
    }

    /// Restore scrollback from disk, if available. Should be called before start().
    public func loadScrollback() {
        guard let url = scrollbackURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            buffer.append(Array(data))
            Log.info("pane \(id) loaded \(data.count) bytes of scrollback")
        } catch {
            Log.warn("pane \(id) failed to load scrollback: \(error)")
        }
    }

    /// Flush ring buffer contents to disk.
    public func persistScrollback() {
        guard let url = scrollbackURL else { return }
        let snapshot = buffer.snapshot()
        guard !snapshot.isEmpty else { return }
        do {
            try Data(snapshot).write(to: url, options: .atomic)
        } catch {
            Log.warn("pane \(id) failed to persist scrollback: \(error)")
        }
    }
}
