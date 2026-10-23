import Foundation

/// JSON helpers for the engine's string-in, string-out command interface. Never throws, never crashes:
/// non-finite numbers become `null`, unsupported values are dropped.
enum JSONBridge {
    /// Encodes command params. Returns "{}" when nothing can be encoded.
    static func encode(_ params: [String: Any]) -> String {
        let clean = sanitize(params)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Parses any JSON (objects, arrays, fragments). Nil for empty or invalid text.
    static func decode(_ text: String) -> Any? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func decodeObject(_ text: String) -> [String: Any]? {
        decode(text) as? [String: Any]
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        case is NSNull:
            return value
        default:
            return NSNull()
        }
    }
}

extension Double {
    /// `self` when finite, else `fallback`.
    func finite(or fallback: Double = 0) -> Double { isFinite ? self : fallback }
}
