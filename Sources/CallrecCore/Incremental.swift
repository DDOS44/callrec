import Foundation

/// Parsed values cached by file identity, so a reload only re-reads files that
/// changed. Identity is (inode, mtime, size): the atomic temp+rename writes
/// MarkdownStore does always change the inode, so an edit can never look unchanged.
public final class ParseCache<Value>: @unchecked Sendable {
    struct Stamp: Equatable {
        let inode: UInt64
        let mtimeSeconds: Int
        let mtimeNanos: Int
        let size: Int64
    }

    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, value: Value)] = [:]
    /// How many files were actually parsed / served from the cache in the last pass. For tests and timing.
    public private(set) var parsed = 0
    public private(set) var reused = 0

    public init() {}

    static func stamp(of url: URL) -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: UInt64(st.st_ino), mtimeSeconds: Int(st.st_mtimespec.tv_sec),
                     mtimeNanos: Int(st.st_mtimespec.tv_nsec), size: Int64(st.st_size))
    }

    /// Call before a pass to reset the counters.
    public func beginPass() {
        lock.lock(); parsed = 0; reused = 0; lock.unlock()
    }

    /// The cached value if the file is unchanged, else `parse(url)` (cached if non-nil).
    public func value(for url: URL, parse: (URL) -> Value?) -> Value? {
        guard let now = Self.stamp(of: url) else {
            lock.lock(); entries[url.path] = nil; lock.unlock()
            return nil
        }
        lock.lock()
        if let hit = entries[url.path], hit.stamp == now {
            reused += 1
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        let fresh = parse(url)   // outside the lock: parsing is the slow part
        lock.lock()
        parsed += 1
        entries[url.path] = fresh.map { (now, $0) }
        lock.unlock()
        return fresh
    }

    /// Forget files that no longer exist.
    public func prune(keeping paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

/// Trailing-edge debounce: the action runs once, `delay` after the last call.
public final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let action: @Sendable () -> Void
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval, queue: DispatchQueue = .main, action: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.queue = queue
        self.action = action
    }

    public func call() {
        let item = DispatchWorkItem { [action] in action() }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func cancel() {
        lock.lock(); pending?.cancel(); pending = nil; lock.unlock()
    }
}

/// "Run at most once per interval", with the clock injected for tests.
public struct Throttle {
    public let interval: TimeInterval
    private var last: Date?

    public init(interval: TimeInterval) { self.interval = interval }

    /// True when the work is due; records `now` as the last run when it is.
    public mutating func shouldRun(now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }

    /// Forces the next `shouldRun` to return true (after a state change you caused yourself).
    public mutating func reset() { last = nil }
}
