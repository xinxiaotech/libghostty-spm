//
//  AppTerminalView+Input.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public extension AppTerminalView {
        override func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override func doCommand(by selector: Selector) {
            inputHandler?.handleTextCommand(selector)
        }

        internal func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        // Position is not re-sent on button events: `mouseMoved` /
        // `mouseDragged` keep libghostty's cursor in sync continuously, and
        // re-stamping position inside press/release perturbs SGR/1006 mouse
        // reports for terminal apps that distinguish move vs click events.
        // Matches upstream SurfaceView_AppKit.mouseDown / mouseUp semantics.

        override func mouseDown(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func mouseUp(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseDown(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseUp(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseDown(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseUp(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        override func mouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            let precision = event.hasPreciseScrollingDeltas
            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            // Upstream ghostty doubles precise-scroll deltas (trackpad /
            // Magic Mouse) because raw AppKit deltas feel sluggish once
            // passed through libghostty's grid-cell conversion. Match that
            // multiplier so trackpad scroll speed is on par with Ghostty.app
            // and Terminal.app.
            if precision {
                x *= 2
                y *= 2
            }
            let scrollMods = TerminalScrollModifiers(
                precision: precision,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(x: x, y: y, mods: scrollMods.rawValue)
        }
    }
#endif
