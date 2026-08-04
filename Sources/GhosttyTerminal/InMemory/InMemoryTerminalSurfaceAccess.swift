import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0

    /// Bytes that arrived before a surface was bound, replayed in order the
    /// moment one is. Without this, hosts that start streaming immediately —
    /// a session-restore replay buffer, or a shell prompt printed before the
    /// view enters its window hierarchy — have those bytes dropped and the
    /// grid comes up blank.
    private var pendingInbound = Data()
    /// Soft cap so a host that never binds a surface can't balloon the
    /// process. Past the cap we keep the tail, which is the part that
    /// determines visible terminal state.
    private let pendingInboundCap = 10 * 1024 * 1024

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit
    ) {
        self.write = write
        self.processExit = processExit
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        self.surface = nil
        waitForActiveOperations()
        self.surface = surface

        // Drain only once a surface is actually bound; clearing to nil must
        // keep the buffer so the bytes survive until the next bind.
        let pending: Data
        if surface != nil {
            pending = pendingInbound
            pendingInbound = Data()
        } else {
            pending = Data()
        }
        let generation = self.generation
        condition.unlock()

        guard !pending.isEmpty else { return }
        // Enqueued before any write the caller makes after setSurface
        // returns, so the replay lands ahead of live output.
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                write(surface, pending)
            }
        }
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations()
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    /// Returns false only when the data was neither enqueued nor retained.
    @discardableResult
    func enqueueWrite(_ data: Data) -> Bool {
        condition.lock()
        guard surface != nil else {
            pendingInbound.append(data)
            if pendingInbound.count > pendingInboundCap {
                pendingInbound = pendingInbound.suffix(pendingInboundCap)
            }
            condition.unlock()
            return true
        }
        let generation = self.generation
        condition.unlock()

        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                write(surface, data)
            }
        }
        return true
    }

    @discardableResult
    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
        return true
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    func waitForPendingOutput() {
        outputQueue.sync {}
    }

    private var currentGeneration: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return surface == nil ? nil : generation
    }

    private func withSurface(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Void
    ) {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        operation(surface)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func waitForActiveOperations() {
        while activeOperations > 0 {
            condition.wait()
        }
    }
}
