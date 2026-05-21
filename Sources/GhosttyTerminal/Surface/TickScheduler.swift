//
//  TickScheduler.swift
//  libghostty-spm
//
//  Strategy types for dispatching the per-frame work driven by the
//  display link (`TerminalSurfaceCoordinator.tick`). The default
//  `InlineTickScheduler` matches the legacy behavior of calling
//  `ghostty_surface_draw` synchronously on the caller's thread.
//
//  `OffMainTickScheduler` and `DroppingTickScheduler` exist so we can
//  evaluate solutions for the main-thread hangs seen when libghostty's
//  Metal renderer calls `MTLCommandBuffer.waitUntilCompleted` under GPU
//  pressure. See Tests/GhosttyKitTest/TerminalTickSchedulerTests.swift
//  for the verification.
//

import Foundation

/// Submits per-frame work to wherever it should actually run.
///
/// Implementations decide:
///   - which thread executes `work` (caller, or a dedicated render queue);
///   - whether to drop newly-arrived work while a previous tick is still in flight.
///
/// `work` is the synchronous Metal draw + present pipeline; on macOS this
/// includes any internal `MTLCommandBuffer.waitUntilCompleted` inside libghostty.
public protocol TickScheduler: AnyObject, Sendable {
    func schedule(_ work: @escaping @Sendable () -> Void)

    /// Block the caller until any in-flight or queued work submitted via
    /// `schedule` has finished. Used at surface teardown to ensure no
    /// outstanding draw still references the soon-to-be-freed surface.
    func drain()
}

/// Baseline — runs work synchronously on the caller's thread.
///
/// If called from the main thread (as the current Chime/libghostty-spm
/// pipeline does), the main thread will block for the full duration of
/// the draw, including any internal GPU wait.
public final class InlineTickScheduler: TickScheduler, @unchecked Sendable {
    public init() {}
    public func schedule(_ work: @escaping @Sendable () -> Void) {
        work()
    }
    public func drain() { /* synchronous — nothing to wait for */ }
}

/// Solution A — serializes draws on a dedicated background queue.
///
/// `schedule(_:)` returns immediately to the caller. The main thread is
/// never blocked on GPU completion, but rapidly-arriving ticks will queue
/// up behind a slow draw. Pair with `DroppingTickScheduler` to coalesce.
public final class OffMainTickScheduler: TickScheduler, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String = "dev.chime.terminal.render", qos: DispatchQoS = .userInteractive) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    public func schedule(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    public func drain() {
        queue.sync {}
    }
}

/// Solution C — wraps any scheduler, dropping ticks that arrive while a
/// previous tick is still pending or executing.
///
/// Guarantees at most one outstanding tick at any time. With a slow draw
/// and a fast display link (e.g. 120Hz vsync, 50ms draws), this prevents
/// unbounded backlog and keeps latency current rather than letting the
/// queue grow.
public final class DroppingTickScheduler: TickScheduler, @unchecked Sendable {
    private let inner: TickScheduler
    private let lock = NSLock()
    private var busy = false
    private var _droppedCount = 0
    private var _completedCount = 0

    public init(wrapping inner: TickScheduler) {
        self.inner = inner
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedCount
    }

    public var completedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _completedCount
    }

    public func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        if busy {
            _droppedCount += 1
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        inner.schedule { [weak self] in
            work()
            guard let self else { return }
            self.lock.lock()
            self._completedCount += 1
            self.busy = false
            self.lock.unlock()
        }
    }

    public func drain() {
        inner.drain()
    }
}
