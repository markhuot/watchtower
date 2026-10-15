import Foundation

/// Wire frame: 4-byte big-endian payload length, then 1-byte type tag, then payload bytes.
/// Total frame size = 4 + 1 + payload.count. The 4-byte length covers tag + payload.
///
/// This format is transport-agnostic. Same frames flow over Unix sockets locally and would
/// flow over TCP / WebSocket binary frames for mobile.
public enum MessageType: UInt8 {
    // Control (JSON payloads)
    case hello       = 0x01
    case welcome     = 0x02
    case listPanes   = 0x03
    case panes       = 0x04
    case openPane    = 0x05
    case opened      = 0x06
    case attach      = 0x07
    case attached    = 0x08
    case detach      = 0x09
    case closePane   = 0x0A
    case resize      = 0x0B
    case paneExited  = 0x0C
    case errorMsg    = 0x0D

    // Data (binary payloads, prefixed with 16-byte pane UUID)
    case input       = 0x20
    case output      = 0x21
    case scrollback  = 0x22
}

public struct Frame {
    public let type: MessageType
    public let payload: Data

    public init(type: MessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: 5 + payload.count)
        let length = UInt32(payload.count + 1).bigEndian  // +1 for the tag byte
        var lenBE = length
        withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }
}

/// Parses incoming bytes into frames. Caller feeds chunks; receives complete frames.
public final class FrameParser {
    /// Maximum frame payload size we'll accept (1 + payload). Defends against bad/abusive input.
    public static let maxFrameSize: Int = 64 * 1024 * 1024  // 64 MB

    private var buffer: Data = Data()

    public init() {}

    public func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Try to extract the next complete frame. Returns nil when more bytes are needed.
    /// Throws if the wire is malformed (oversize frame, invalid type tag).
    public func nextFrame() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.withUnsafeBytes { ptr -> UInt32 in
            let raw = ptr.loadUnaligned(as: UInt32.self)
            return UInt32(bigEndian: raw)
        })
        if length < 1 {
            throw WireError.malformed("frame length < 1 (no room for type tag)")
        }
        if length > Self.maxFrameSize {
            throw WireError.malformed("frame length \(length) exceeds max \(Self.maxFrameSize)")
        }
        let totalNeeded = 4 + length
        guard buffer.count >= totalNeeded else { return nil }

        let typeByte = buffer[buffer.startIndex + 4]
        guard let type = MessageType(rawValue: typeByte) else {
            // Skip past this frame to recover, then surface an error.
            buffer.removeFirst(totalNeeded)
            throw WireError.unknownType(typeByte)
        }

        let payloadStart = buffer.startIndex + 5
        let payloadEnd = buffer.startIndex + totalNeeded
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        buffer.removeFirst(totalNeeded)
        return Frame(type: type, payload: payload)
    }
}

public enum WireError: Error, CustomStringConvertible {
    case malformed(String)
    case unknownType(UInt8)

    public var description: String {
        switch self {
        case .malformed(let m): return "malformed frame: \(m)"
        case .unknownType(let b): return String(format: "unknown frame type 0x%02X", b)
        }
    }
}
