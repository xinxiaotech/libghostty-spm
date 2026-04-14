//
//  AppTerminalView+Pasteboard.swift
//  libghostty-spm
//
//  Wires the standard NSResponder pasteboard selectors (copy:, paste:)
//  to ghostty's built-in binding actions. `selectAll:` lives on the class
//  proper since it requires an `override` that extensions can't express.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public extension AppTerminalView {
        @objc func copy(_ sender: Any?) {
            _ = surface?.performBindingAction("copy_to_clipboard")
        }

        @objc func paste(_ sender: Any?) {
            _ = surface?.performBindingAction("paste_from_clipboard")
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
