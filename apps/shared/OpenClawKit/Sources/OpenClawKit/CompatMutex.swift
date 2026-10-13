import os

/// iOS 17 backport of the `Synchronization.Mutex` surface used in this package.
///
/// `Mutex` requires iOS 18 / watchOS 11 / macOS 15. `OSAllocatedUnfairLock` (iOS 16+)
/// provides the same unfair-lock semantics; `withLockUnchecked` keeps `Mutex.withLock`'s
/// non-`@Sendable`, synchronous closure shape so call sites stay unchanged.
public struct CompatMutex<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ initialValue: Value) {
        self.lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try self.lock.withLockUnchecked(body)
    }
}
