import Foundation

public enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public final class Log {
    public static var level: LogLevel = .info

    private static let queue = DispatchQueue(label: "watchtower.broker.log")
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    public static func debug(_ s: @autoclosure () -> String) { emit(.debug, s()) }
    public static func info(_ s: @autoclosure () -> String) { emit(.info, s()) }
    public static func warn(_ s: @autoclosure () -> String) { emit(.warn, s()) }
    public static func error(_ s: @autoclosure () -> String) { emit(.error, s()) }

    private static func emit(_ lvl: LogLevel, _ msg: String) {
        guard lvl >= level else { return }
        let ts = dateFormatter.string(from: Date())
        let line = "\(ts) [\(lvl.label)] \(msg)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
