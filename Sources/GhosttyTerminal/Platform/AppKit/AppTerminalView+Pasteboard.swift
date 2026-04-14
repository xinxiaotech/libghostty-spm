//
//  AppTerminalView+Pasteboard.swift
//  libghostty-spm
//
//  Wires the standard NSResponder pasteboard selectors (copy:, paste:,
//  selectAll:) to ghostty's built-in binding actions so that macOS's
//  default Edit menu, keyboard shortcuts, and context menus "just work"
//  over a focused AppTerminalView.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public extension AppTerminalView {
        // These match the NSResponder action-selector names. NSResponder
        // doesn't declare them as Swift-visible methods so we can't use
        // `override`; @objc is enough for the Objective-C responder chain
        // dispatch used by the Edit menu and standard keyboard shortcuts.
        @objc func copy(_ sender: Any?) {
            _ = surface?.performBindingAction("copy_to_clipboard")
        }

        @objc func paste(_ sender: Any?) {
            _ = surface?.performBindingAction("paste_from_clipboard")
        }

        @objc func selectAll(_ sender: Any?) {
            _ = surface?.performBindingAction("select_all")
        }

        /// Performs an arbitrary ghostty binding action (e.g. `clear_screen`,
        /// `scroll_to_bottom`). Returns false if the action is unknown or
        /// the surface is gone.
        @discardableResult
        func performGhosttyAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
        }
    }
#endif
