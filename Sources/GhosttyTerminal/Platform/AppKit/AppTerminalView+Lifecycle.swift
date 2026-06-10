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
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
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
