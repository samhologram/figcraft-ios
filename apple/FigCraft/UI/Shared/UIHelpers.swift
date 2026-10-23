import SwiftUI
import UIKit
@preconcurrency import FigCraftKit

/// A decoded engine JSON object (`node.get`, command results).
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func number(_ key: String) -> Double? {
        guard let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? {
        guard let n = self[key] as? NSNumber else { return nil }
        return n.boolValue
    }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func objects(_ key: String) -> [JSONObject] { (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
    func numbers(_ key: String) -> [Double] {
        (self[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }
}

extension EditorModel {
    /// Runs a read-only engine query without touching the editor state (no refresh, no undo registration).
    func query(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        guard let text = try? handle.execute(id: id, paramsJson: JSONBridge.encode(params)) else { return nil }
        return JSONBridge.decode(text)
    }

    /// `node.get` of any node (the selection's JSON only covers a single selected node).
    func nodeObject(_ id: UInt64) -> JSONObject? {
        guard let text = try? handle.nodeJson(id: id) else { return nil }
        return JSONBridge.decodeObject(text)
    }

    /// The engine type name of the single selected node ("FRAME", "TEXT", ...).
    var selectionType: String { selectionJSON?.string("type") ?? "" }

    var selectionIsFrameLike: Bool { ["FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE", "SECTION"].contains(selectionType) }

    /// Layers the prototype can navigate to: top-level frames of the page (frames in sections too).
    var navigationFrames: [LayerRow] {
        let sections = Set(layers.filter { $0.kind == "section" }.map(\.id))
        return layers.filter { row in
            guard row.kind == "frame" || row.kind == "component" || row.kind == "componentSet" else { return false }
            guard let parent = row.parent else { return true }
            return sections.contains(parent)
        }
    }
}

enum Humanize {
    /// "strokeWeight" -> "Stroke weight".
    static func key(_ key: String) -> String {
        var out = ""
        for ch in key {
            if out.isEmpty {
                out.append(contentsOf: ch.uppercased())
            } else if ch.isUppercase {
                out.append(" ")
                out.append(contentsOf: ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// "BOOLEAN_OPERATION" -> "Boolean operation".
    static func nodeType(_ type: String) -> String {
        let words = type.lowercased().split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func number(_ value: Double, decimals: Int = 2) -> String {
        guard value.isFinite else { return "0" }
        let factor = pow(10, Double(decimals))
        let r = (value * factor).rounded() / factor
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        return String(r)
    }
}

/// SF Symbols for tools, kinds and actions. Names validated against `CoreGlyphs.bundle/name_availability.plist`.
enum Symbols {
    static func tool(_ id: String) -> String {
        switch id {
        case "move": "cursorarrow"
        case "hand": "hand.raised"
        case "scale": "arrow.up.left.and.arrow.down.right"
        case "frame": "number.square"
        case "section": "rectangle.split.3x1"
        case "slice": "crop"
        case "rectangle": "rectangle"
        case "line": "line.diagonal"
        case "arrow": "arrow.up.right"
        case "ellipse": "circle"
        case "polygon": "hexagon"
        case "star": "star"
        case "pen": "pencil.tip"
        case "pencil": "pencil"
        case "shapeBuilder": "circle.square"
        case "text": "textformat"
        case "comment": "bubble.left"
        case "eyedropper": "eyedropper"
        default: "square.dashed"
        }
    }

    static func group(_ key: String) -> String {
        switch key {
        case "move": "cursorarrow"
        case "frame": "number.square"
        case "shape": "rectangle"
        case "pen": "pencil.tip"
        case "text": "textformat"
        case "comment": "bubble.left"
        default: "square.dashed"
        }
    }

    static func layerKind(_ kind: String) -> String {
        switch kind {
        case "frame": "number.square"
        case "group": "square.on.square"
        case "section": "rectangle.split.3x1"
        case "rectangle": "rectangle"
        case "ellipse": "circle"
        case "polygon": "hexagon"
        case "star": "star"
        case "line": "line.diagonal"
        case "vector": "pencil.and.outline"
        case "text": "textformat"
        case "booleanOp": "square.on.circle"
        case "component": "diamond.fill"
        case "componentSet": "square.grid.2x2"
        case "instance": "diamond"
        case "slice": "crop"
        default: "square.dashed"
        }
    }
}

// MARK: Colours

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" (css hex as the engine writes it).
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let r, g, b, a: Double
        if text.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// "#RRGGBB" (alpha dropped; paints carry their opacity separately).
    func hexString() -> String {
        let resolved = resolve(in: EnvironmentValues())
        func byte(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    }
}

extension View {
    /// `control.<propKey>` accessibility identifier of an inspector field.
    func control(_ key: String) -> some View { accessibilityIdentifier("control.\(key)") }
}
