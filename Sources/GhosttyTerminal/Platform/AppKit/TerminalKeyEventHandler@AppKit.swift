//
//  TerminalKeyEventHandler@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class TerminalKeyEventHandler {
        private weak var view: AppTerminalView?
        var inputMethodHandler: TerminalTextInputHandler?

        init(view: AppTerminalView) {
            self.view = view
            inputMethodHandler = TerminalTextInputHandler(view: view)
        }

        func handleKeyDown(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            if handleDirectInputIfNeeded(event) {
                return
            }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // Command-modded keys don't run through IME / text translation —
            // forward them straight through. (performKeyEquivalent, which
            // upstream ghostty uses for keybind-aware Cmd routing, is not
            // implemented here yet.)
            guard !event.modifierFlags.contains(.command) else {
                sendKeyEvent(
                    for: event, action: action, to: surface,
                    includeText: false, composing: false, translationEvent: nil
                )
                return
            }

            // Ask libghostty which modifiers apply for character translation.
            // This honors configs like `macos-option-as-alt` — without it,
            // e.g. Option+E would always produce the dead-key "´" instead of
            // the user's chosen behavior. Upstream SurfaceView_AppKit.swift
            // does the same via `ghostty_surface_key_translation_mods`.
            let translationEvent = makeTranslationEvent(for: event, surface: surface)

            // Snapshot preedit state BEFORE `interpretKeyEvents`. CJK IMEs
            // collapse their preedit in response to Backspace / Escape by
            // calling `setMarkedText("")` / `unmarkText()`. Without this
            // snapshot the key would leak to the PTY after the IME cancelled
            // the composition, deleting a real character sitting in front of
            // what the user was composing. Mirrors upstream ghostty's
            // `markedTextBefore` flag in `SurfaceView_AppKit.keyDown`.
            let markedTextBefore = inputMethodHandler?.hasMarkedText == true

            inputMethodHandler?.startCollectingText()
            view.interpretKeyEvents([translationEvent])

            if inputMethodHandler?.consumeHandledTextCommand() == true {
                return
            }

            if let collected = inputMethodHandler?.finishCollectingText() {
                var input = event.buildKeyInput(
                    action: action, composing: false,
                    translationEvent: translationEvent
                )
                for text in collected {
                    text.withCString { ptr in
                        input.text = ptr
                        surface.sendKeyEvent(input)
                    }
                }
                return
            }

            // Always call through to libghostty; use the `composing` bit to
            // tell it whether this keystroke belongs to an active (or
            // just-cancelled) IME composition. libghostty's key encoder
            // suppresses text output when composing, so Backspace won't leak
            // to the PTY — replaces the ad-hoc early-return guard we used
            // before threading this flag through.
            let markedTextNow = inputMethodHandler?.hasMarkedText == true
            let composing = markedTextBefore || markedTextNow
            sendKeyEvent(
                for: event, action: action, to: surface,
                includeText: true, composing: composing,
                translationEvent: translationEvent
            )
        }

        /// Apply `ghostty_surface_key_translation_mods` to the event's
        /// modifiers and, if anything changed, return a synthesized NSEvent
        /// carrying the translated mods + re-derived characters. When the
        /// translation is a no-op we return the original event so object
        /// identity is preserved — AppKit's input context is sensitive to
        /// that for certain Korean / dead-key sequences (upstream notes the
        /// same gotcha).
        private func makeTranslationEvent(
            for event: NSEvent,
            surface: TerminalSurface
        ) -> NSEvent {
            let rawGhosttyMods = TerminalInputModifiers(from: event.modifierFlags).ghosttyMods
            let translatedGhosttyMods = surface.translationMods(for: rawGhosttyMods)
            let translatedSet = TerminalInputModifiers(rawValue: translatedGhosttyMods.rawValue)
            let translatedNSFlags = translatedSet.nsModifierFlags

            // Upstream comment: the event carries hidden bits (dead-key
            // state, etc.) we mustn't replace wholesale. Only toggle the
            // four user-facing modifiers from the translation result; leave
            // everything else on `event.modifierFlags` untouched.
            var translationModifierFlags = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translatedNSFlags.contains(flag) {
                    translationModifierFlags.insert(flag)
                } else {
                    translationModifierFlags.remove(flag)
                }
            }

            if translationModifierFlags == event.modifierFlags {
                return event
            }

            return NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationModifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationModifierFlags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        func handleTextCommand(_ selector: Selector) {
            inputMethodHandler?.handleCommand(selector)
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
            if shouldBypassGhosttyForDirectInput(event) {
                return
            }
            var input = event.buildKeyInput(
                action: GHOSTTY_ACTION_RELEASE, composing: false,
                translationEvent: nil
            )
            input.text = nil
            surface.sendKeyEvent(input)
        }

        func handleFlagsChanged(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            let action: ghostty_input_action_e = isModifierPress(event)
                ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

            var input = event.buildKeyInput(
                action: action, composing: false,
                translationEvent: nil
            )
            input.text = nil
            surface.sendKeyEvent(input)
        }

        private func isModifierPress(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
            switch event.keyCode {
            case 56, 60: return flags.contains(.shift)
            case 58, 61: return flags.contains(.option)
            case 59, 62: return flags.contains(.control)
            case 55, 54: return flags.contains(.command)
            case 57: return flags.contains(.capsLock)
            default: return false
            }
        }

        private func sendKeyEvent(
            for event: NSEvent,
            action: ghostty_input_action_e,
            to surface: TerminalSurface,
            includeText: Bool,
            composing: Bool,
            translationEvent: NSEvent?
        ) {
            var input = event.buildKeyInput(
                action: action, composing: composing,
                translationEvent: translationEvent
            )
            // Characters come from the translated event when available so
            // that `macos-option-as-alt` et al. produce the right bytes.
            let textSource = translationEvent ?? event
            guard includeText,
                  let chars = textSource.filteredCharacters,
                  !chars.isEmpty
            else {
                surface.sendKeyEvent(input)
                return
            }

            chars.withCString { ptr in
                input.text = ptr
                surface.sendKeyEvent(input)
            }
        }

        private func handleDirectInputIfNeeded(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            // During IME composition, AppKit needs to keep ownership of editing
            // commands so marked text can shrink, cancel, and move correctly.
            guard inputMethodHandler?.hasMarkedText != true else { return false }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            let delivery = TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            )
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = view.configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func shouldBypassGhosttyForDirectInput(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            return TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            ).isDirectInput
        }
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        func buildKeyInput(
            action: ghostty_input_action_e,
            composing: Bool,
            translationEvent: NSEvent?
        ) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            // libghostty's `ghostty_input_key_s.keycode` is `uint32_t` and is
            // interpreted as the platform-native virtual keycode (NSEvent
            // keyCode on macOS). The core translates it through its own
            // per-platform table to resolve cursor keys, function keys, etc.
            //
            // The previous implementation stored `ghostty_input_key_e.rawValue`
            // here, which libghostty cannot interpret as a macOS keyCode — so
            // key binding lookups for arrow keys, backspace, and friends
            // returned false and no bytes were emitted to the PTY. Upstream
            // `ghostty-org/ghostty`'s macOS app passes the raw `UInt32(keyCode)`
            // here (see `macos/Sources/Ghostty/NSEvent+Extension.swift`).
            input.keycode = UInt32(keyCode)
            input.composing = composing
            input.text = nil

            // `mods` uses the raw event modifiers so keybind matching sees
            // what the user actually pressed. `consumed_mods` uses the
            // translated modifiers (minus control/command, which the
            // binding system needs) so libghostty knows which mods were
            // already absorbed by text translation. Matches upstream
            // ghostty's `NSEvent+Extension.ghosttyKeyEvent` split.
            input.mods = TerminalInputModifiers(from: modifierFlags).ghosttyMods

            var consumedFlags = (translationEvent ?? self).modifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            input.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            if type == .keyDown || type == .keyUp,
               let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                input.unshifted_codepoint = codepoint.value
            }

            return input
        }

        var filteredCharacters: String? {
            guard let characters else { return nil }
            guard characters.count == 1,
                  let scalar = characters.unicodeScalars.first
            else {
                return characters
            }

            // macOS encodes function keys as Private Use Area scalars —
            // these have no printable representation.
            if TerminalInputText.isPrivateUseFunctionKey(scalar) {
                return nil
            }

            // When the control modifier produces a raw control character,
            // re-derive printable text without the control modifier so
            // Ghostty can map the physical key correctly.
            if scalar.isASCIIControl {
                var flags = modifierFlags
                flags.remove(.control)
                return self.characters(byApplyingModifiers: flags)
            }

            return characters
        }
    }

    extension UnicodeScalar {
        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif
