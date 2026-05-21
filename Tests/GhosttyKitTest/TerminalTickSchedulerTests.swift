//
//  TerminalTickSchedulerTests.swift
//
//  Compares the three candidate fixes for the main-thread hang observed
//  when libghostty's Metal renderer calls `MTLCommandBuffer.waitUntilCompleted`
//  under GPU pressure:
//
//    - Baseline (`InlineTickScheduler`)        — current behavior.
//    - Solution A (`OffMainTickScheduler`)     — draw on a dedicated queue.
//    - Solution C (`DroppingTickScheduler`)    — drop overlapping ticks.
//
//  Solution B (replace `waitUntilCompleted` with `addCompletedHandler` +
//  semaphore inside libghostty's Zig code) is not exercised here because
//  it lives below the Swift FFI boundary. To validate B you would build
//  libghostty with an instrumented `Metal.zig` that records wall-clock
//  time spent inside `waitUntilCompleted`, then compare distributions
//  before/after the patch under the same workload that drives these tests.
//
//  The tests substitute the real `ghostty_surface_draw` with a deterministic
//  delay that models a stalled `waitUntilCompleted` (the `__psynch_cvwait`
//  stack frame from the hang reports). They measure two properties that
//  matter at the application level:
//
//    1. Main-thread responsiveness — does an unrelated main-queue task
//       round-trip within a small budget while ticks are firing?
//       (This is the "UI did not freeze" property.)
//    2. Backlog control — how many ticks completed vs. arrived, with no
//       unbounded queue growth under sustained slow draws.
//
//  All tests dispatch tick work onto the real main queue and measure on
//  the test thread, mirroring the runtime path:
//      CVDisplayLink → DispatchQueue.main.async → coordinator.tick().
//

@testable import GhosttyTerminal
import Foundation
import Testing

// MARK: - Helpers

/// Models the synchronous Metal draw + present, including a stalled
/// `waitUntilCompleted`. `Thread.sleep` parks the kernel thread the same
/// way a `__psynch_cvwait` does, so it is the closest cheap model of the
/// observed hang frame.
@Sendable
private func simulateSlowDraw(_ duration: TimeInterval) {
    Thread.sleep(forTimeInterval: duration)
}

/// Measures wall-clock latency between dispatching a no-op to the main
/// queue and seeing it actually run. Called from the test thread (NOT
/// main) so the dispatch can land while main is busy.
///
/// Returns once the no-op has run, or `timeout` seconds — whichever
/// comes first. A value at or above `timeout` indicates main was still
/// blocked.
private func mainQueueRoundTrip(timeout: TimeInterval = 5) -> TimeInterval {
    let semaphore = DispatchSemaphore(value: 0)
    let start = CFAbsoluteTimeGetCurrent()
    DispatchQueue.main.async { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + timeout)
    return CFAbsoluteTimeGetCurrent() - start
}

/// Dispatch `body` onto the real main queue, returning its result.
/// Models the CVDisplayLink → main hop.
private func runOnMain<T>(_ body: () -> T) -> T {
    DispatchQueue.main.sync(execute: body)
}

/// Void variant.
private func runOnMain(_ body: () -> Void) {
    DispatchQueue.main.sync(execute: body)
}

// MARK: - Tests

/// These tests measure shared resource — the main queue. They must NOT
/// run concurrently with each other, otherwise the inline-storm tests
/// (which deliberately freeze main) would invalidate the responsiveness
/// assertions of the off-main tests.
@Suite(.serialized)
struct TerminalTickSchedulerTests {

    // ---------------------------------------------------------------
    // BASELINE: confirm the hang
    // ---------------------------------------------------------------

    /// Inline scheduler called from main blocks the caller for the full
    /// draw duration. This is the property that causes UI freezes when
    /// libghostty's internal `waitUntilCompleted` runs long.
    @Test(.timeLimit(.minutes(1)))
    func baseline_inlineScheduler_blocksCaller() {
        let scheduler = InlineTickScheduler()
        let slowDraw: TimeInterval = 0.250

        let elapsed: TimeInterval = runOnMain {
            let start = CFAbsoluteTimeGetCurrent()
            scheduler.schedule { simulateSlowDraw(slowDraw) }
            return CFAbsoluteTimeGetCurrent() - start
        }

        #expect(elapsed >= slowDraw * 0.9,
                "InlineTickScheduler should block caller; got \(elapsed)s")
    }

    /// End-to-end demonstration of the freeze: when a burst of inline
    /// ticks runs on main, an independent main-queue task is delayed
    /// roughly `tickCount * drawDuration`. This is the tripwire test —
    /// if the coordinator ever ends up wired to InlineTickScheduler in
    /// production, this test reproduces the freeze.
    @Test(.timeLimit(.minutes(1)))
    func baseline_inline_freezesMainQueue() {
        let scheduler = InlineTickScheduler()
        let slowDraw: TimeInterval = 0.100
        let tickCount = 5

        // Queue the storm and the sentinel back-to-back on main. The main
        // queue is FIFO, so the sentinel runs only after the storm
        // finishes — measured latency ≈ tickCount * drawDuration.
        let sentinel = DispatchSemaphore(value: 0)
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }
        DispatchQueue.main.async { sentinel.signal() }
        _ = sentinel.wait(timeout: .now() + 10)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let expected = slowDraw * Double(tickCount)
        #expect(elapsed >= expected * 0.8,
                "Inline must hold main for ~tickCount*draw; got \(elapsed)s, expected ~\(expected)s")
    }

    // ---------------------------------------------------------------
    // SOLUTION A: off-main draw
    // ---------------------------------------------------------------

    /// Off-main scheduler returns to the caller immediately. This is the
    /// fundamental property that prevents the hang regardless of how
    /// long libghostty waits on the GPU.
    @Test(.timeLimit(.minutes(1)))
    func solutionA_offMain_returnsImmediately() {
        let scheduler = OffMainTickScheduler(label: "test.render.A")
        let slowDraw: TimeInterval = 0.250
        let done = DispatchSemaphore(value: 0)

        let elapsed: TimeInterval = runOnMain {
            let start = CFAbsoluteTimeGetCurrent()
            scheduler.schedule {
                simulateSlowDraw(slowDraw)
                done.signal()
            }
            return CFAbsoluteTimeGetCurrent() - start
        }

        #expect(elapsed < 0.020,
                "Off-main scheduler must return within ~ms; got \(elapsed)s")
        _ = done.wait(timeout: .now() + 5)
    }

    /// A burst of slow ticks dispatched through the off-main scheduler
    /// leaves the main queue responsive to unrelated work.
    @Test(.timeLimit(.minutes(1)))
    func solutionA_keepsMainQueueResponsive() {
        let scheduler = OffMainTickScheduler(label: "test.render.A2")
        let slowDraw: TimeInterval = 0.100
        let tickCount = 10

        // Storm runs on main but each schedule returns instantly, so the
        // sentinel queued after the storm fires near-instantly.
        let sentinel = DispatchSemaphore(value: 0)
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }
        DispatchQueue.main.async { sentinel.signal() }
        _ = sentinel.wait(timeout: .now() + 5)
        let sentinelLatency = CFAbsoluteTimeGetCurrent() - start

        #expect(sentinelLatency < 0.050,
                "Main queue should stay responsive; got \(sentinelLatency)s")
    }

    /// Off-main alone serializes ticks FIFO — without dropping, a fast
    /// display link + slow draw still builds a backlog (each draw runs
    /// to completion, total time ≈ N*draw). Establishes the motivation
    /// for combining A with C.
    @Test(.timeLimit(.minutes(2)))
    func solutionA_alone_letsBacklogGrow() {
        let scheduler = OffMainTickScheduler(label: "test.render.A-backlog")
        let slowDraw: TimeInterval = 0.050
        let tickCount = 10
        let group = DispatchGroup()

        runOnMain {
            for _ in 0..<tickCount {
                group.enter()
                scheduler.schedule {
                    simulateSlowDraw(slowDraw)
                    group.leave()
                }
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        _ = group.wait(timeout: .now() + 5)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let expected = slowDraw * Double(tickCount)
        #expect(elapsed >= expected * 0.7,
                "Without dropping, off-main serializes ticks; elapsed=\(elapsed)s, expected ~\(expected)s")
    }

    // ---------------------------------------------------------------
    // SOLUTION C: drop overlapping ticks
    // ---------------------------------------------------------------

    /// With dropping in front of off-main, a burst against a slow draw
    /// coalesces: at most one tick in flight at a time, the rest are
    /// dropped. Every tick is accounted for (completed + dropped == N).
    @Test(.timeLimit(.minutes(1)))
    func solutionC_droppingCoalescesOverlaps() {
        let scheduler = DroppingTickScheduler(
            wrapping: OffMainTickScheduler(label: "test.render.C")
        )
        let slowDraw: TimeInterval = 0.100
        let tickCount = 20

        runOnMain {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }

        // Allow any in-flight draw to finish.
        Thread.sleep(forTimeInterval: slowDraw * 3)

        let completed = scheduler.completedCount
        let dropped = scheduler.droppedCount

        #expect(completed + dropped == tickCount,
                "Every tick accounted for; completed=\(completed) dropped=\(dropped)")
        #expect(completed <= 2,
                "Backlog coalesced; completed=\(completed)")
        #expect(dropped >= tickCount - 2,
                "Most ticks dropped; dropped=\(dropped)")
    }

    // ---------------------------------------------------------------
    // COMBINED: A + C (intended production wiring)
    // ---------------------------------------------------------------

    /// Both properties at once: main stays responsive AND backlog
    /// coalesces. This is the configuration we should ship.
    @Test(.timeLimit(.minutes(1)))
    func solutionAplusC_responsiveAndCoalesced() {
        let scheduler = DroppingTickScheduler(
            wrapping: OffMainTickScheduler(label: "test.render.AC")
        )
        let slowDraw: TimeInterval = 0.100
        let tickCount = 15

        let sentinel = DispatchSemaphore(value: 0)
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }
        DispatchQueue.main.async { sentinel.signal() }
        _ = sentinel.wait(timeout: .now() + 5)
        let sentinelLatency = CFAbsoluteTimeGetCurrent() - start

        // Let any in-flight draw finish.
        Thread.sleep(forTimeInterval: slowDraw * 3)

        #expect(sentinelLatency < 0.050,
                "Main queue responsive; latency=\(sentinelLatency)s")
        #expect(scheduler.completedCount <= 2,
                "Backlog coalesced; completed=\(scheduler.completedCount)")
        #expect(scheduler.completedCount + scheduler.droppedCount == tickCount,
                "All ticks accounted for")
    }

    // ---------------------------------------------------------------
    // CROSS-CHECK: probe via mainQueueRoundTrip during the storm
    // ---------------------------------------------------------------

    /// A second angle on responsiveness: probe the main queue from the
    /// test thread *while* the inline storm is running. Should observe a
    /// large round-trip — main is held by the inline draws.
    @Test(.timeLimit(.minutes(1)))
    func crossCheck_inline_mainRoundTripIsLong() {
        let scheduler = InlineTickScheduler()
        let slowDraw: TimeInterval = 0.100
        let tickCount = 5

        DispatchQueue.main.async {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }
        // Give main a beat to start the storm before we probe.
        Thread.sleep(forTimeInterval: 0.020)
        let rtt = mainQueueRoundTrip(timeout: 5)

        #expect(rtt >= slowDraw,
                "Main round-trip during inline storm should exceed one draw; rtt=\(rtt)s")
    }

    /// The off-main counterpart: probing main during the storm shows a
    /// fast round-trip because main is idle.
    @Test(.timeLimit(.minutes(1)))
    func crossCheck_offMain_mainRoundTripIsShort() {
        let scheduler = OffMainTickScheduler(label: "test.render.cross-A")
        let slowDraw: TimeInterval = 0.100
        let tickCount = 5

        DispatchQueue.main.async {
            for _ in 0..<tickCount {
                scheduler.schedule { simulateSlowDraw(slowDraw) }
            }
        }
        Thread.sleep(forTimeInterval: 0.020)
        let rtt = mainQueueRoundTrip(timeout: 5)

        #expect(rtt < 0.020,
                "Main round-trip during off-main storm should be ~ms; rtt=\(rtt)s")
    }
}
