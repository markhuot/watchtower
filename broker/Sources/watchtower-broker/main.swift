import Foundation
import WatchtowerBrokerCore
import Darwin

// Quick CLI: `watchtower-broker [--debug] [--root <path>]`
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--debug":
        Log.level = .debug
    case "--root":
        if let path = args.next() {
            BrokerPaths.rootOverride = URL(fileURLWithPath: path, isDirectory: true)
        }
    case "--help", "-h":
        print("""
        watchtower-broker - persistent PTY broker for Watchtower
        Usage: watchtower-broker [--debug] [--root <dir>]
          --debug         enable debug logging
          --root <dir>    override the broker support directory
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
        exit(2)
    }
}

let broker: Broker
do {
    broker = try Broker()
    broker.loadOrphanedScrollback()
    try broker.start()
} catch {
    FileHandle.standardError.write(Data("broker failed to start: \(error)\n".utf8))
    exit(1)
}

// SIGTERM / SIGINT → graceful shutdown.
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: broker.queue)
termSource.setEventHandler {
    Log.info("SIGTERM — stopping")
    broker.stop()
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)

let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: broker.queue)
intSource.setEventHandler {
    Log.info("SIGINT — stopping")
    broker.stop()
    exit(0)
}
intSource.resume()
signal(SIGINT, SIG_IGN)

// Reap any zombie children that slipped past per-pane handling.
signal(SIGCHLD, SIG_DFL)

dispatchMain()
