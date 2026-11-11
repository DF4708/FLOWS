// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import Foundation
import Security
import os

// THE UNSAFE ISLANDS (this folder, Core/Islands).
//
// Swift checks memory and data-race safety for everything it can prove. A
// few things it cannot prove: a pointer handed to a C function, an object
// passed through a C callback, a value shared between tasks on a promise the
// compiler cannot read. Each of those lives in this folder, behind a safe
// call, with the promise it rests on written beside it. No other FLOWS file
// may use those tools: rust/flows-bridge/tests/swift_unsafe_islands.rs
// fails on one that does.

/// A Rust handle shared between tasks.
///
/// PROMISE: the holder makes no mutating call on the handle once the value
/// has been handed to another task. swift-bridge handles are plain owned
/// pointers into Rust; Rust reads through `&self` are safe from any thread.
struct RustShared<Handle>: @unchecked Sendable {
    let handle: Handle
    init(_ handle: Handle) { self.handle = handle }
}

/// An ISO 8601 date parser shared between tasks.
///
/// PROMISE: Foundation documents `ISO8601DateFormatter` as thread-safe, and
/// its options are set once, before it is shared, and never again.
struct SharedISO8601Parser: @unchecked Sendable {
    private let parser: ISO8601DateFormatter

    init(_ options: ISO8601DateFormatter.Options) {
        let made = ISO8601DateFormatter()
        made.formatOptions = options
        parser = made
    }

    func date(from text: String) -> Date? { parser.date(from: text) }
    func string(from date: Date) -> String { parser.string(from: date) }
}

/// Formatters kept by key. Building a `DateFormatter` or `NumberFormatter` is
/// among the dearest things Foundation does, and view code asked for one per
/// label per redraw (a schedule's clock faces, a fare, a ferry's season).
///
/// PROMISE: a formatter is only ever touched inside the lock, by `make` and
/// by `use`, and neither lets it out.
final class FormatterShelf<F: Formatter>: Sendable {
    private let byKey = OSAllocatedUnfairLock<[String: F]>(uncheckedState: [:])

    /// Run `use` on the formatter kept under `key`, building it with `make`
    /// the first time. A shelf that has grown past 40 is emptied (zones and
    /// locales are few; this only bounds a pathological caller).
    func with<T>(_ key: String, make: () -> F, _ use: (F) -> T) -> T {
        byKey.withLockUnchecked { kept in
            if let found = kept[key] { return use(found) }
            let made = make()
            if kept.count > 40 { kept.removeAll() }
            kept[key] = made
            return use(made)
        }
    }
}

/// Notification observers kept by name, removed when replaced, cleared, or
/// when the holder goes away (so a `deinit` off the main actor can drop
/// them without touching actor state).
///
/// PROMISE: the tokens are only read and written inside the lock, and
/// `NotificationCenter.removeObserver` may be called from any thread.
final class ObserverSlots: Sendable {
    private let slots = OSAllocatedUnfairLock<[String: NSObjectProtocol]>(uncheckedState: [:])

    /// Keep `token` under `name`, removing the observer it replaces.
    func set(_ name: String, _ token: NSObjectProtocol) {
        let old = slots.withLockUnchecked { kept in kept.updateValue(token, forKey: name) }
        if let old { NotificationCenter.default.removeObserver(old) }
    }

    func remove(_ name: String) {
        let old = slots.withLockUnchecked { kept in kept.removeValue(forKey: name) }
        if let old { NotificationCenter.default.removeObserver(old) }
    }

    func removeAll() {
        let all = slots.withLockUnchecked { kept -> [NSObjectProtocol] in
            defer { kept.removeAll() }
            return Array(kept.values)
        }
        for token in all { NotificationCenter.default.removeObserver(token) }
    }

    deinit { removeAll() }
}

/// Byte work that needs a pointer for the length of one system call.
///
/// PROMISE (each function): the pointer comes from a buffer this function
/// owns, the count given to the system is that buffer's own count, and the
/// pointer does not outlive the closure it was lent to.
enum RawBytes {
    /// `count` bytes from the system's secure random source; nil if it
    /// refuses (the caller must not go on with predictable bytes).
    static func secureRandom(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var bytes = Data(count: count)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count == count else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        return ok ? bytes : nil
    }

    /// Inflate a raw DEFLATE stream into at most `capacity` bytes. Returns
    /// the bytes written, which is `capacity` when the stream did not fit;
    /// nil when nothing could be decoded.
    static func inflate(_ deflated: Data, capacity: Int) -> Data? {
        guard !deflated.isEmpty, capacity > 0 else { return nil }
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            deflated.withUnsafeBytes { src -> Int in
                guard let to = dst.bindMemory(to: UInt8.self).baseAddress,
                    let from = src.bindMemory(to: UInt8.self).baseAddress,
                    dst.count == capacity
                else { return 0 }
                return compression_decode_buffer(
                    to, capacity, from, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }

    /// Write all of `data` to an open stream; the count the stream took.
    static func write(_ data: Data, to stream: OutputStream) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return stream.write(base, maxLength: raw.count)
        }
    }
}

/// An object a main-queue callback hands to the main actor.
///
/// Apple's delegate callbacks (CoreBluetooth here) arrive as plain,
/// unisolated calls even when the manager was told to deliver them on the
/// main queue, and the objects they carry are not `Sendable`.
///
/// PROMISE: the value is wrapped inside a callback that is already running
/// on the main queue, and the compiler lets it be read back only on the main
/// actor, so it never leaves the main thread.
struct MainQueueOnly<Value>: @unchecked Sendable {
    private let held: Value
    init(_ value: Value) { held = value }
    @MainActor var value: Value { held }
}

/// One timer, kept where a deinit (which runs off the actor) can stop it.
///
/// PROMISE: the timer is only stored and invalidated here, never read back,
/// and every swap happens under the lock, so no timer is invalidated twice
/// or left running after its slot is gone.
final class TimerSlot: Sendable {
    private let slot = OSAllocatedUnfairLock<Timer?>(uncheckedState: nil)

    /// Keep `timer` (or nothing), stopping the one it replaces.
    func set(_ timer: Timer?) {
        let old = slot.withLockUnchecked { kept -> Timer? in
            defer { kept = timer }
            return kept
        }
        old?.invalidate()
    }

    deinit { set(nil) }
}
