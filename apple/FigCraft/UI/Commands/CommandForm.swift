import SwiftUI
@preconcurrency import FigCraftKit

/// Editable state of the generic parameter sheet: one value per `ParamField`, and the conversion back to the JSON
/// object of the engine command. A field is sent when it is required or the user switched it on (untouched
/// optional fields never override the engine's own defaults).
@MainActor @Observable
final class CommandForm {
    struct FormError: Error { let message: String }

    let commandID: String
    /// Fields with a control (the free-form pseudo field and `ids` are not here).
    let fields: [ParamField]
    let usesSelection: Bool
    let freeFormLabel: String?

    var numbers: [String: Double] = [:]
    var texts: [String: String] = [:]
    var flags: [String: Bool] = [:]
    var included: Set<String> = []
    var freeJSON = ""

    init(commandID: String, selection: [UInt64] = []) {
        self.commandID = commandID
        let all = CommandCatalog.shared.params(commandID)
        usesSelection = all.contains { $0.kind == "ids" }
        freeFormLabel = all.first { $0.key.isEmpty }?.label
        fields = all.filter { !$0.key.isEmpty && $0.kind != "ids" }
        for f in fields {
            let def = Self.decode(f.defaultJson)
            switch f.kind {
            case "number", "integer":
                var v = (def as? NSNumber)?.doubleValue ?? f.min ?? 0
                if let lo = f.min { v = max(lo, v) }
                if let hi = f.max { v = min(hi, v) }
                numbers[f.key] = v.isFinite ? v : 0
            case "bool":
                flags[f.key] = (def as? NSNumber)?.boolValue ?? false
            case "choice":
                var wanted = ""
                if let s = def as? String { wanted = s } else if let n = def as? NSNumber { wanted = Self.numberText(n.doubleValue) }
                texts[f.key] = f.choices.contains(wanted) ? wanted : (f.choices.first ?? "")
            case "json":
                texts[f.key] = def.map { Self.pretty($0) } ?? ""
            case "color":
                texts[f.key] = (def as? String) ?? "#000000"
            case "id":
                if let n = (def as? NSNumber)?.uint64Value {
                    texts[f.key] = String(n)
                } else if selection.count == 1, let only = selection.first {
                    texts[f.key] = String(only)
                } else {
                    texts[f.key] = ""
                }
            default:
                texts[f.key] = (def as? String) ?? ""
            }
            if !f.isOptional { included.insert(f.key) }
        }
    }

    private static func decode(_ json: String?) -> Any? {
        guard let json else { return nil }
        return JSONBridge.decode(json)
    }

    static func numberText(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    static func pretty(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(any)" }
        return s
    }

    func isMissingRequired(_ f: ParamField) -> Bool {
        guard !f.isOptional else { return false }
        switch f.kind {
        case "string", "json", "id", "color": return (texts[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    var canRun: Bool { !fields.contains(where: isMissingRequired) }

    /// The JSON object for the engine, from the controls plus the free-form JSON.
    func params() throws -> [String: Any] {
        var out: [String: Any] = [:]
        for f in fields where included.contains(f.key) {
            switch f.kind {
            case "number":
                out[f.key] = numbers[f.key] ?? 0
            case "integer":
                out[f.key] = Int(((numbers[f.key] ?? 0).rounded()).clamped(-1e15, 1e15))
            case "bool":
                out[f.key] = flags[f.key] ?? false
            case "choice":
                let t = texts[f.key] ?? ""
                if !f.choices.isEmpty, f.choices.allSatisfy({ Double($0) != nil }), let n = Double(t), n.isFinite {
                    out[f.key] = n.rounded() == n && abs(n) < 1e15 ? (Int(n) as Any) : (n as Any)
                } else {
                    out[f.key] = t
                }
            case "json":
                let t = (texts[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                guard let data = t.data(using: .utf8),
                      let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw FormError(message: "\u{201C}\(f.label)\u{201D} is not valid JSON.")
                }
                out[f.key] = v
            case "id":
                let t = (texts[f.key] ?? "").trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                guard let n = UInt64(t) else { throw FormError(message: "\u{201C}\(f.label)\u{201D} must be a layer id (a whole number).") }
                out[f.key] = n
            default:
                let t = texts[f.key] ?? ""
                if !t.isEmpty || !f.isOptional { out[f.key] = t }
            }
        }
        let free = freeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty {
            guard let data = free.data(using: .utf8),
                  let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FormError(message: "The extra parameters must be a JSON object.")
            }
            out.merge(v) { _, new in new }
        }
        return out
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
