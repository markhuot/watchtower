import Foundation

/// Control-message payloads (JSON). Data-frame payloads (`input`/`output`/`scrollback`) are
/// raw binary: 16 UUID bytes followed by terminal bytes. They have no struct here.

public struct HelloMessage: Codable {
    public var client: String
    public var version: Int
    public init(client: String, version: Int = 1) {
        self.client = client
        self.version = version
    }
}

public struct WelcomeMessage: Codable {
    public var brokerVersion: String
    public var serverId: String
    public init(brokerVersion: String, serverId: String) {
        self.brokerVersion = brokerVersion
        self.serverId = serverId
    }
}

public struct PaneSummary: Codable {
    public var id: String
    public var title: String
    public var cols: UInt16
    public var rows: UInt16
    public var alive: Bool
    public init(id: String, title: String, cols: UInt16, rows: UInt16, alive: Bool) {
        self.id = id
        self.title = title
        self.cols = cols
        self.rows = rows
        self.alive = alive
    }
}

public struct PanesMessage: Codable {
    public var panes: [PaneSummary]
    public init(panes: [PaneSummary]) { self.panes = panes }
}

public struct OpenPaneMessage: Codable {
    public var cwd: String?
    public var command: [String]?
    public var env: [String: String]?
    public var cols: UInt16
    public var rows: UInt16
    public var title: String?
    public init(cwd: String? = nil, command: [String]? = nil, env: [String: String]? = nil,
                cols: UInt16, rows: UInt16, title: String? = nil) {
        self.cwd = cwd
        self.command = command
        self.env = env
        self.cols = cols
        self.rows = rows
        self.title = title
    }
}

public struct OpenedMessage: Codable {
    public var paneId: String
    public init(paneId: String) { self.paneId = paneId }
}

public struct AttachMessage: Codable {
    public var paneId: String
    public var replayScrollback: Bool
    public init(paneId: String, replayScrollback: Bool = true) {
        self.paneId = paneId
        self.replayScrollback = replayScrollback
    }
}

public struct AttachedMessage: Codable {
    public var paneId: String
    public var cols: UInt16
    public var rows: UInt16
    public init(paneId: String, cols: UInt16, rows: UInt16) {
        self.paneId = paneId
        self.cols = cols
        self.rows = rows
    }
}

public struct DetachMessage: Codable {
    public var paneId: String
    public init(paneId: String) { self.paneId = paneId }
}

public struct ClosePaneMessage: Codable {
    public var paneId: String
    public init(paneId: String) { self.paneId = paneId }
}

public struct ResizeMessage: Codable {
    public var paneId: String
    public var cols: UInt16
    public var rows: UInt16
    public init(paneId: String, cols: UInt16, rows: UInt16) {
        self.paneId = paneId
        self.cols = cols
        self.rows = rows
    }
}

public struct PaneExitedMessage: Codable {
    public var paneId: String
    public var exitCode: Int32
    public init(paneId: String, exitCode: Int32) {
        self.paneId = paneId
        self.exitCode = exitCode
    }
}

public struct ErrorMessage: Codable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Codec helpers

public enum WireCoder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func encode<T: Encodable>(_ message: T, type: MessageType) throws -> Frame {
        let payload = try encoder.encode(message)
        return Frame(type: type, payload: payload)
    }

    public static func decode<T: Decodable>(_ frame: Frame, as: T.Type) throws -> T {
        return try decoder.decode(T.self, from: frame.payload)
    }

    /// Build a data frame: 16-byte pane UUID prefix + raw bytes.
    public static func dataFrame(type: MessageType, paneId: UUID, bytes: Data) -> Frame {
        var payload = Data(capacity: 16 + bytes.count)
        var u = paneId.uuid
        withUnsafeBytes(of: &u) { payload.append(contentsOf: $0) }
        payload.append(bytes)
        return Frame(type: type, payload: payload)
    }

    /// Parse the data-frame prefix into (paneId, body).
    public static func splitDataFrame(_ frame: Frame) -> (UUID, Data)? {
        guard frame.payload.count >= 16 else { return nil }
        let uuidBytes = frame.payload.prefix(16)
        let body = frame.payload.dropFirst(16)
        var bytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        let arr = Array(uuidBytes)
        bytes.0 = arr[0]; bytes.1 = arr[1]; bytes.2 = arr[2]; bytes.3 = arr[3]
        bytes.4 = arr[4]; bytes.5 = arr[5]; bytes.6 = arr[6]; bytes.7 = arr[7]
        bytes.8 = arr[8]; bytes.9 = arr[9]; bytes.10 = arr[10]; bytes.11 = arr[11]
        bytes.12 = arr[12]; bytes.13 = arr[13]; bytes.14 = arr[14]; bytes.15 = arr[15]
        return (UUID(uuid: bytes), body)
    }
}
