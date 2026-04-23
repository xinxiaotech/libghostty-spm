//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Bytes that arrived before libghostty had a surface bound. Flushed to
    /// the surface the moment `setSurface` binds one. Without this buffer,
    /// clients that start streaming output immediately (e.g. a chime-shell-
    /// server replay buffer delivered at pane-restore time, or a shell
    /// prompt printed before the pane's NSView enters its window hierarchy)
    /// would have bytes silently dropped and the grid would stay blank.
    private var pendingInbound = Data()
    /// Soft cap so a client that never attaches a surface can't balloon the
    /// process. 10 MiB is roughly one full default scrollback — plenty for
    /// an attach replay.
    private let pendingInboundCap: Int = 10 * 1024 * 1024

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        // We must NOT hold `lock` across `ghostty_surface_write_buffer`: feeding
        // bytes into libghostty can block until its termio worker drains, and
        // that worker may re-enter this object on another thread via the
        // resize callback (`dispatchResize`). Holding the lock across the
        // write deadlocks main ↔ io thread — visible as a frozen UI on large
        // replay buffers at pane-restore time.
        lock.lock()
        self.surface = surface
        let pending = pendingInbound
        pendingInbound = Data()
        lock.unlock()

        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
        if let surface, !pending.isEmpty {
            TerminalDebugLog.log(
                .output,
                "in-memory flush pending \(pending.count) bytes on surface attach"
            )
            pending.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
            }
        }
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        // Snapshot the surface under the lock, then release before feeding
        // bytes into libghostty — see `setSurface` for the deadlock this
        // avoids.
        lock.lock()
        guard let surface else {
            // Surface not attached yet — buffer until it is. Bounded so a
            // broken client can't ask us to hold forever; past the cap we
            // keep only the tail (most recent bytes), which for a terminal
            // stream is usually what matters for visual state.
            pendingInbound.append(data)
            if pendingInbound.count > pendingInboundCap {
                pendingInbound = pendingInbound.suffix(pendingInboundCap)
            }
            let total = pendingInbound.count
            lock.unlock()
            TerminalDebugLog.log(
                .output,
                "terminal <- host buffered \(data.count) bytes (total pending \(total))"
            )
            return
        }
        lock.unlock()

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        // Snapshot the surface under the lock, then release before calling
        // into libghostty — see `setSurface` for the deadlock this avoids.
        lock.lock()
        let surface = self.surface
        lock.unlock()
        guard let surface else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        lock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
