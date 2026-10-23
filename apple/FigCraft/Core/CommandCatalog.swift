import SwiftUI
@preconcurrency import FigCraftKit

/// The data-driven command system: wraps the engine catalog (`commandCatalog()`), the desktop menu layout
/// (`menuLayout()`) and the tool groups (`toolGroups()`). Menus, the palette and the parameter sheets are
/// generated from it, so new engine commands appear without Swift changes.
@MainActor
final class CommandCatalog {
    static let shared = CommandCatalog()

    let commands: [CommandInfo]
    /// Desktop menu bar order (File ... Help, Tools last).
    let menus: [MenuSection]
    let toolGroups: [ToolGroup]

    private let byID: [String: CommandInfo]
    private var paramCache: [String: [ParamField]] = [:]
    private var supportCache: [String: String?] = [:]

    private init() {
        let all = commandCatalog()
        commands = all
        menus = menuLayout()
        toolGroups = FigCraftKit.toolGroups()
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func command(_ id: String) -> CommandInfo? { byID[id] }
    func isKnown(_ id: String) -> Bool { byID[id] != nil }
    func label(_ id: String) -> String { byID[id]?.label ?? id }

    /// Parsed desktop shortcut of a command (nil for none or anything SwiftUI cannot express).
    func shortcut(_ id: String) -> KeyboardShortcut? {
        guard let text = byID[id]?.shortcut else { return nil }
        return Self.parseShortcut(text)
    }

    func shortcutText(_ id: String) -> String? { byID[id]?.shortcut }

    func params(_ id: String) -> [ParamField] {
        if let cached = paramCache[id] { return cached }
        let fields = commandParams(id: id)
        paramCache[id] = fields
        return fields
    }

    /// True when running the command should first ask for parameters (any required field).
    func needsParams(_ id: String) -> Bool {
        params(id).contains { !$0.key.isEmpty && !$0.isOptional }
    }

    /// True for commands that make no sense on iOS (`ios-excluded-commands.txt`).
    func isExcluded(_ id: String) -> Bool {
        if let cached = supportCache[id] { return cached != nil }
        let reason = commandPlatformSupport(id: id)
        supportCache[id] = .some(reason)
        return reason != nil
    }

    // MARK: Shortcut parsing

    /// Parses egui notation: "Cmd+Shift+R", "Shift+G", "E", "=", "Escape".
    nonisolated static func parseShortcut(_ text: String) -> KeyboardShortcut? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "", parts.count >= 2 {
            parts.removeLast()
            parts[parts.count - 1] = "+"
        }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let key: KeyEquivalent
        switch keyName.lowercased() {
        case "backspace": key = .delete
        case "delete": key = .deleteForward
        case "enter", "return": key = .return
        case "tab": key = .tab
        case "space": key = .space
        case "esc", "escape": key = .escape
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        default:
            guard keyName.count == 1, let ch = keyName.lowercased().first else { return nil }
            key = KeyEquivalent(ch)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// "Cmd+Shift+R" to a symbol string for the palette.
    nonisolated static func display(_ text: String) -> String {
        text.split(separator: "+", omittingEmptySubsequences: false).map { part -> String in
            switch part.lowercased() {
            case "cmd": "\u{2318}"
            case "shift": "\u{21E7}"
            case "alt": "\u{2325}"
            case "ctrl": "\u{2303}"
            case "backspace": "\u{232B}"
            case "delete": "\u{2326}"
            case "enter": "\u{21A9}"
            case "escape": "\u{238B}"
            default: String(part).uppercased()
            }
        }.joined()
    }
}
