import Foundation
import Darwin

/// One connected client. Reads frames off the socket fd and dispatches them via `onFrame`.
/// Writes are buffered and flushed when the fd is writable.
public final class ClientConnection {
    public let id: UUID = UUID()
    public let fd: Int32
    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?

    /// Pane IDs this client is currently attached to (subscribed to OUTPUT).
    public var attachedPanes: Set<UUID> = []

    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private let parser = FrameParser()
    private var pending: Data = Data()
    private var closed = false

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    public func start() {
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { [weak self] in self?.readAvailable() }
        r.setCancelHandler { [fd] in close(fd) }
        readSource = r
        r.resume()

        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        w.setEventHandler { [weak self] in self?.flush() }
        // Suspend initially; resume when we have data.
        writeSource = w
    }

    private var writeSourceActive = false

    public func send(_ frame: Frame) {
        guard !closed else { return }
        pending.append(frame.encode())
        if !writeSourceActive {
            writeSourceActive = true
            writeSource?.resume()
        }
    }

    private func flush() {
        if pending.isEmpty {
            if writeSourceActive {
                writeSource?.suspend()
                writeSourceActive = false
            }
            return
        }
        let n = pending.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return Darwin.write(fd, base, pending.count)
        }
        if n > 0 {
            pending.removeFirst(n)
            if pending.isEmpty {
                if writeSourceActive {
                    writeSource?.suspend()
                    writeSourceActive = false
                }
            }
        } else if n < 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
            Log.debug("client \(id) write error: \(String(cString: strerror(e))); closing")
            closeConnection()
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
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
                Log.warn("client \(id) frame error: \(error); closing")
                closeConnection()
            }
        } else if n == 0 {
            closeConnection()
        } else {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
            Log.debug("client \(id) read error: \(String(cString: strerror(e))); closing")
            closeConnection()
        }
    }

    public func closeConnection() {
        guard !closed else { return }
        closed = true

        readSource?.cancel()
        readSource = nil

        // writeSource must be resumed before cancel; releasing a suspended source crashes.
        if let w = writeSource {
            if !writeSourceActive {
                w.resume()
            }
            w.cancel()
        }
        writeSourceActive = false
        writeSource = nil

        // The fd is closed by readSource's cancel handler.

        onClose?()
    }
}
