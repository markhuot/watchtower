import Foundation

/// Bounded byte ring buffer.
/// Single-threaded — caller is responsible for synchronization.
public final class RingBuffer {
    public let capacity: Int
    private var storage: [UInt8]
    private var head: Int = 0  // next write position
    private var count: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    public var byteCount: Int { count }
    public var isEmpty: Bool { count == 0 }

    public func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        // If incoming chunk is bigger than capacity, only keep the trailing capacity bytes.
        let totalIn = bytes.count
        if totalIn >= capacity {
            // Replace whole buffer with the last `capacity` bytes of input.
            let dropping = totalIn - capacity
            var i = 0
            for (idx, byte) in bytes.enumerated() {
                if idx < dropping { continue }
                storage[i] = byte
                i += 1
            }
            head = 0
            count = capacity
            return
        }

        // Normal path: write byte-by-byte, advancing head, evicting oldest by overwrite.
        for byte in bytes {
            storage[head] = byte
            head = (head + 1) % capacity
            if count < capacity {
                count += 1
            }
        }
    }

    /// Snapshot the contents in chronological order (oldest first, newest last).
    public func snapshot() -> [UInt8] {
        if count == 0 { return [] }
        if count < capacity {
            // head points to next write slot; oldest is at index 0.
            return Array(storage[0..<count])
        }
        // Buffer is full; oldest is at head, newest is at head-1 (wrapped).
        var out = [UInt8]()
        out.reserveCapacity(count)
        out.append(contentsOf: storage[head..<capacity])
        out.append(contentsOf: storage[0..<head])
        return out
    }

    public func clear() {
        head = 0
        count = 0
    }
}
