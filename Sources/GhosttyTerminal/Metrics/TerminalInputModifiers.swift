//
//  TerminalInputModifiers.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public struct TerminalInputModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalInputModifiers(rawValue: 1 << 0)
    public static let ctrl = TerminalInputModifiers(rawValue: 1 << 1)
    public static let alt = TerminalInputModifiers(rawValue: 1 << 2)
    public static let super_ = TerminalInputModifiers(rawValue: 1 << 3)
    public static let caps = TerminalInputModifiers(rawValue: 1 << 4)
    public static let num = TerminalInputModifiers(rawValue: 1 << 5)
    public static let shiftRight = TerminalInputModifiers(rawValue: 1 << 6)
    public static let ctrlRight = TerminalInputModifiers(rawValue: 1 << 7)
    public static let altRight = TerminalInputModifiers(rawValue: 1 << 8)
    public static let superRight = TerminalInputModifiers(rawValue: 1 << 9)

    public var ghosttyMods: ghostty_input_mods_e {
        ghostty_input_mods_e(rawValue)
    }

    #if canImport(UIKit)
        public init(from flags: UIKeyModifierFlags) {
            var mods = TerminalInputModifiers()
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.control) { mods.insert(.ctrl) }
            if flags.contains(.alternate) { mods.insert(.alt) }
            if flags.contains(.command) { mods.insert(.super_) }
            if flags.contains(.alphaShift) { mods.insert(.caps) }
            if flags.contains(.numericPad) { mods.insert(.num) }
            self = mods
        }

    #elseif canImport(AppKit)
        public init(from flags: NSEvent.ModifierFlags) {
            var mods = TerminalInputModifiers()
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.control) { mods.insert(.ctrl) }
            if flags.contains(.option) { mods.insert(.alt) }
            if flags.contains(.command) { mods.insert(.super_) }
            if flags.contains(.capsLock) { mods.insert(.caps) }
            // Intentionally do NOT map `.numericPad` to `.num`. AppKit sets
            // `.numericPad` on every arrow / function key whose physical
            // location is on the keypad, regardless of whether num-lock is
            // engaged (and Mac keyboards have no meaningful num-lock state).
            // Forwarding it as a kitty-keyboard `num` modifier made bare
            // arrow keys encode as e.g. `\e[1;129A`, which TUIs interpret
            // as "arrow with num_lock held" and ignore.
            self = mods
        }

        /// Reverse of `init(from: NSEvent.ModifierFlags)`, used when libghostty
        /// returns translated modifiers (via `ghostty_surface_key_translation_mods`)
        /// and we need to re-express them as AppKit flags for `NSEvent.keyEvent`.
        public var nsModifierFlags: NSEvent.ModifierFlags {
            var flags = NSEvent.ModifierFlags()
            if contains(.shift) { flags.insert(.shift) }
            if contains(.ctrl) { flags.insert(.control) }
            if contains(.alt) { flags.insert(.option) }
            if contains(.super_) { flags.insert(.command) }
            if contains(.caps) { flags.insert(.capsLock) }
            if contains(.num) { flags.insert(.numericPad) }
            return flags
        }
    #endif
}
