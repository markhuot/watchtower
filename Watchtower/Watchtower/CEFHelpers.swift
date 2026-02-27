import Foundation
import os

private let logger = Logger(subsystem: "com.watchtower", category: "CEFHelpers")

// MARK: - Reference Counting

/// Atomic reference count stored alongside each client-side CEF struct allocation.
/// Layout: [Int32 refcount (padded to alignment)] [CEF struct bytes]
///
/// Uses `OSAtomicIncrement32Barrier` / `OSAtomicDecrement32Barrier` for lock-free
/// atomic operations. This avoids the use-after-free that occurs with lock-based
/// counting: when refcount hits 0 the allocation is freed immediately, so any
/// lock stored in the freed memory becomes invalid for concurrent callers.
///
/// The CEF struct's `base.add_ref`/`release`/etc. callbacks use pointer arithmetic
/// to find the refcount header.

/// The byte offset from the start of the allocation to the CEF struct.
/// Must be large enough to hold an Int32 and maintain alignment.
private let cefRefCountHeaderSize = 16  // plenty of room for Int32 + alignment padding

/// Given a pointer to a `cef_base_ref_counted_t` that was allocated by `cefCreate`,
/// returns a pointer to the `Int32` refcount stored in the allocation header.
private func cefRefCountPtr(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>) -> UnsafeMutablePointer<Int32> {
    let raw = UnsafeMutableRawPointer(base) - cefRefCountHeaderSize
    return raw.bindMemory(to: Int32.self, capacity: 1)
}

/// Allocate and zero-initialize a CEF C struct of type `T`, setting up its
/// `cef_base_ref_counted_t` with working reference counting callbacks.
///
/// The returned pointer is owned by the caller with an initial refcount of 1.
/// When CEF calls `release` and the count drops to 0, the allocation is freed.
///
/// Usage:
/// ```
/// let client: UnsafeMutablePointer<cef_client_t> = cefCreate()
/// client.pointee.base.size = MemoryLayout<cef_client_t>.size
/// // ... populate function pointers ...
/// ```
func cefCreate<T>() -> UnsafeMutablePointer<T> {
    let structSize = MemoryLayout<T>.size
    let alignment = max(MemoryLayout<T>.alignment, MemoryLayout<Int32>.alignment)

    // Allocate: [Int32 refcount + padding] [T struct]
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: cefRefCountHeaderSize + structSize,
        alignment: alignment
    )

    // Initialize the refcount to 1
    let rcPtr = raw.bindMemory(to: Int32.self, capacity: 1)
    rcPtr.pointee = 1

    // Zero-initialize the struct region
    let structPtr = (raw + cefRefCountHeaderSize).bindMemory(to: T.self, capacity: 1)
    memset(UnsafeMutableRawPointer(structPtr), 0, structSize)

    // Set up base ref counted callbacks.
    // This assumes the first field of T is `cef_base_ref_counted_t base`.
    let basePtr = UnsafeMutableRawPointer(structPtr)
        .bindMemory(to: cef_base_ref_counted_t.self, capacity: 1)

    basePtr.pointee.size = structSize
    basePtr.pointee.add_ref = { selfPtr in
        guard let selfPtr = selfPtr else { return }
        let rcPtr = cefRefCountPtr(selfPtr)
        OSAtomicIncrement32Barrier(rcPtr)
    }
    basePtr.pointee.release = { selfPtr -> Int32 in
        guard let selfPtr = selfPtr else { return 0 }
        let rcPtr = cefRefCountPtr(selfPtr)
        let newCount = OSAtomicDecrement32Barrier(rcPtr)
        if newCount == 0 {
            // We are the sole owner. Free the allocation.
            let raw = UnsafeMutableRawPointer(selfPtr) - cefRefCountHeaderSize
            raw.deallocate()
            return 1
        }
        return 0
    }
    basePtr.pointee.has_one_ref = { selfPtr -> Int32 in
        guard let selfPtr = selfPtr else { return 0 }
        let rcPtr = cefRefCountPtr(selfPtr)
        return OSAtomicAdd32Barrier(0, rcPtr) == 1 ? 1 : 0
    }
    basePtr.pointee.has_at_least_one_ref = { selfPtr -> Int32 in
        guard let selfPtr = selfPtr else { return 0 }
        let rcPtr = cefRefCountPtr(selfPtr)
        return OSAtomicAdd32Barrier(0, rcPtr) >= 1 ? 1 : 0
    }

    return structPtr
}

// MARK: - String Conversion

/// Convert a Swift `String` to a `cef_string_t` (UTF-16).
/// The resulting `cef_string_t` owns a copy of the data (via `cef_string_utf16_set` with copy=1).
/// You must call `cef_string_utf16_clear` (or `cef_string_clear`) when done.
func cefStringSet(_ string: String, cefStr: inout cef_string_t) {
    let utf16 = Array(string.utf16)
    utf16.withUnsafeBufferPointer { buf in
        // char16_t and UInt16 are layout-compatible; rebind for the C API
        buf.baseAddress!.withMemoryRebound(to: char16_t.self, capacity: utf16.count) { ptr in
            cef_string_utf16_set(ptr, utf16.count, &cefStr, 1)
        }
    }
}

/// Convert a `cef_string_t` (UTF-16) to a Swift `String`.
/// Returns an empty string if the cef_string is empty or null.
func cefStringToSwift(_ cefStr: cef_string_t) -> String {
    guard let strPtr = cefStr.str, cefStr.length > 0 else { return "" }
    // char16_t is UInt16 on macOS; rebind to construct the UTF-16 array
    return strPtr.withMemoryRebound(to: UInt16.self, capacity: cefStr.length) { ptr in
        let buffer = UnsafeBufferPointer(start: ptr, count: cefStr.length)
        return String(utf16CodeUnits: Array(buffer), count: cefStr.length)
    }
}

/// Convert a `cef_string_t` pointer (UTF-16) to a Swift `String`.
func cefStringToSwift(_ cefStr: UnsafePointer<cef_string_t>?) -> String {
    guard let cefStr = cefStr else { return "" }
    return cefStringToSwift(cefStr.pointee)
}

/// Convert a `cef_string_userfree_t` to a Swift `String`, then free the userfree string.
func cefStringUserfreeToSwift(_ userfree: cef_string_userfree_t?) -> String {
    guard let userfree = userfree else { return "" }
    let result = cefStringToSwift(userfree.pointee)
    cef_string_userfree_utf16_free(userfree)
    return result
}

/// Execute a block with a temporary `cef_string_t` created from a Swift `String`.
/// The `cef_string_t` is cleared after the block returns.
func withCEFString<R>(_ string: String, body: (inout cef_string_t) -> R) -> R {
    var cefStr = cef_string_t()
    cefStringSet(string, cefStr: &cefStr)
    let result = body(&cefStr)
    cef_string_utf16_clear(&cefStr)
    return result
}

// MARK: - Userdata Helpers

/// Store a Swift object as an opaque pointer suitable for CEF userdata fields.
func cefRetainedPointer<T: AnyObject>(_ obj: T) -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(obj).toOpaque()
}

/// Retrieve a Swift object from an opaque CEF userdata pointer without consuming the reference.
func cefUnretainedObject<T: AnyObject>(_ ptr: UnsafeMutableRawPointer, as type: T.Type) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

/// Release a retained Swift object from an opaque CEF userdata pointer.
func cefReleasePointer<T: AnyObject>(_ ptr: UnsafeMutableRawPointer, as type: T.Type) {
    Unmanaged<T>.fromOpaque(ptr).release()
}
