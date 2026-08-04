//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    public extension AppTerminalView {
        internal func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            return result
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                core.rebuildIfReady()
                updateColorScheme()
                pushOcclusionState()

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeOcclusionState),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
                // `viewDidChangeBackingProperties` alone is not a dependable
                // signal for a scale change. It doesn't fire at all when the
                // display configuration changes underneath a stationary
                // window (resolution switch, monitor plugged/unplugged), and
                // when it does fire during a drag between screens AppKit may
                // not have finished adopting the new backing scale yet. These
                // three notifications cover the cases the override misses;
                // the handler is cheap and idempotent when nothing moved.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeBackingProperties),
                    name: NSWindow.didChangeBackingPropertiesNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(screenParametersDidChange),
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            } else {
                core.freeSurface()
                NotificationCenter.default.removeObserver(self)
            }
        }

        @objc internal func windowDidBecomeKey(_: Notification) {
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
        }

        @objc internal func windowDidResignKey(_: Notification) {
            core.setFocus(false)
        }

        // Occlusion gates libghostty's internal render machinery: an
        // occluded surface stops its vsync display link and skips draws
        // entirely, so minimized/hidden windows cost no render CPU.
        @objc internal func windowDidChangeOcclusionState(_: Notification) {
            pushOcclusionState()
        }

        internal func pushOcclusionState() {
            guard let window else { return }
            surface?.setOcclusion(window.occlusionState.contains(.visible))
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            core.synchronizeMetrics()
        }

        override func layout() {
            super.layout()
            core.synchronizeMetrics()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            handleBackingScaleChange()
        }

        @objc internal func windowDidChangeBackingProperties(_: Notification) {
            handleBackingScaleChange()
        }

        @objc internal func windowDidChangeScreen(_: Notification) {
            handleBackingScaleChange()
        }

        @objc internal func screenParametersDidChange(_: Notification) {
            handleBackingScaleChange()
        }

        /// Re-derives the backing scale and pushes it to libghostty.
        ///
        /// Order matters: the surface is resized first so libghostty knows
        /// its new pixel extent, and the Metal layer's `drawableSize` is
        /// updated afterwards (via `onMetricsUpdate`, plus the explicit call
        /// here for the no-surface-yet case). Doing it the other way round
        /// leaves a window where the drawable has already grown to 2x while
        /// libghostty is still rendering a 1x frame into it — which reads on
        /// screen as blurry text shrunk into a corner of the pane.
        ///
        /// The deferred second pass exists because AppKit delivers these
        /// signals mid-transition: the window can still report the *old*
        /// screen's backing scale at this point, in which case the first
        /// pass re-applies the stale value. Re-running once the current
        /// runloop turn drains picks up the settled value, and costs
        /// nothing when the scale really didn't change.
        internal func handleBackingScaleChange() {
            applyBackingScale()
            Task { @MainActor [weak self] in
                self?.applyBackingScale()
            }
        }

        private func applyBackingScale() {
            core.synchronizeMetrics()
            updateMetalLayerMetrics()
        }

        func fitToSize() {
            core.fitToSize()
        }

        internal func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        internal func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            controller?.setColorScheme(scheme)
        }
    }
#endif
