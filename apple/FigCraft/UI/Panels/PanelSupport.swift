import SwiftUI
@preconcurrency import FigCraftKit

/// Helpers shared by the Assets sections (styles, variables), the selection colours, the prototype settings and
/// the comments / versions sheets. UI-side only: everything goes through `EditorModel.run` / `query`.

extension EditorModel {
    /// Like `run`, but UI requests the command raises are dropped instead of shown as toasts (for commands whose
    /// request has no iOS counterpart, e.g. `proto.presentOptions` -> `present.options`).
    @discardableResult
    func runQuiet(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        var result: Any?
        do {
            let text = try handle.execute(id: id, paramsJson: JSONBridge.encode(params))
            result = JSONBridge.decode(text)
        } catch {
            report(error)
        }
        _ = handle.takeUiRequests()
        refresh()
        return result
    }
}

/// Engine colours: a css hex string, or `{r, g, b, a}` with components 0...1 (raw serde output).
enum EngineColor {
    /// "#RRGGBB" (alpha dropped).
    static func hex(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? JSONObject,
              let r = object.number("r"), let g = object.number("g"), let b = object.number("b") else { return nil }
        func byte(_ v: Double) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    static func alpha(_ value: Any?) -> Double {
        guard let object = value as? JSONObject, let a = object.number("a") else { return 1 }
        return max(0, min(1, a))
    }

    /// Splits typed text ("#RRGGBB", "#RRGGBBAA", "RRGGBB") into a 7-character hex and an alpha (nil when absent).
    static func parse(_ text: String) -> (hex: String, alpha: Double?)? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 8, UInt64(t, radix: 16) != nil else { return nil }
        let rgb = "#" + t.prefix(6).uppercased()
        if t.count == 8, let a = UInt64(t.suffix(2), radix: 16) { return (rgb, Double(a) / 255) }
        return (rgb, nil)
    }
}

// MARK: Name prompt

/// A pending one-line text prompt (rename, new collection, ...). `kind` and `target` are the caller's own tags.
struct NameRequest: Equatable, Identifiable {
    let id = UUID()
    var kind: String
    var title: String
    var initial = ""
    var target = ""
    var confirmLabel = "OK"
}

private struct NamePrompt: ViewModifier {
    @Binding var request: NameRequest?
    let onConfirm: (NameRequest, String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(request?.title ?? "", isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { request = nil } }
            )) {
                TextField("Name", text: $text)
                    .accessibilityIdentifier("prompt.name")
                Button("Cancel", role: .cancel) { request = nil }
                Button(request?.confirmLabel ?? "OK") {
                    if let request { onConfirm(request, text) }
                    request = nil
                }
                .accessibilityIdentifier("prompt.ok")
            }
            .onChange(of: request, initial: true) { _, new in
                if let new { text = new.initial }
            }
    }
}

extension View {
    /// Presents an alert with a text field while `request` is set; `onConfirm` receives the request and the text.
    func namePrompt(_ request: Binding<NameRequest?>, onConfirm: @escaping (NameRequest, String) -> Void) -> some View {
        modifier(NamePrompt(request: request, onConfirm: onConfirm))
    }
}

// MARK: Small shared views

/// A section header row with a trailing menu or buttons, used by the Assets sections.
struct AssetsHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// A round-rectangle button used for full-width actions inside sheets and panels.
struct WideButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(identifier)
    }
}

extension Double {
    /// A JSON id number as a `UInt64` (nil when negative or not finite).
    var asID: UInt64? {
        guard isFinite, self >= 0, self < 1.8e19 else { return nil }
        return UInt64(self)
    }
}
