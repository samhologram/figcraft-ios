import SwiftUI
@preconcurrency import FigCraftKit

/// A numeric field whose label scrubs: dragging on the label changes the value (one undo step per drag, through
/// `beginDrag` / `setProps` / `endDrag`), typing in the field commits on return or when focus leaves.
/// Identifier `control.<key>`; the draggable label is `control.<key>.scrub`.
struct ScrubField: View {
    let model: EditorModel
    let key: String
    let label: String
    let value: Double?
    var unit = ""
    /// Display = value * scale (opacity 0...1 shows as percent).
    var scale = 1.0
    /// Display units per point of drag.
    var step = 1.0
    var range: ClosedRange<Double>?
    var decimals = 2
    /// Overrides `setProps([key: value])`; receives the value in model units.
    var commit: ((Double) -> Void)?

    @State private var text = ""
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    private func display(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return Humanize.number(v * scale, decimals: decimals)
    }

    private func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func send(_ displayValue: Double) {
        let modelValue = clamp(displayValue) / (scale == 0 ? 1 : scale)
        if let commit { commit(modelValue) } else { model.setProps([key: modelValue]) }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 14, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            if dragStart == nil {
                                dragStart = (value ?? 0) * scale
                                model.beginDrag("Change \(label)")
                            }
                            let raw = (dragStart ?? 0) + Double(drag.translation.width) * step
                            let snapped = decimals == 0 ? raw.rounded() : (raw * 100).rounded() / 100
                            send(snapped)
                            text = Humanize.number(clamp(snapped), decimals: decimals)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            model.endDrag()
                        }
                )
                .accessibilityIdentifier("control.\(key).scrub")
                .accessibilityLabel("\(label) (drag to change)")
                .accessibilityAdjustableAction { direction in
                    let current = (value ?? 0) * scale
                    send(current + (direction == .increment ? step * 10 : -step * 10))
                }
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .onSubmit { commitText() }
                .accessibilityIdentifier("control.\(key)")
                .accessibilityLabel(label)
            if !unit.isEmpty { Text(verbatim: unit).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { text = display(value) }
        .onChange(of: value) { _, new in if !focused && dragStart == nil { text = display(new) } }
        .onChange(of: focused) { _, now in if !now { commitText() } }
    }

    private func commitText() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else {
            text = display(value)
            return
        }
        if let current = value, abs(current * scale - v) < 1e-9 { return }
        send(v)
    }
}

/// A text field that commits on return or when focus leaves, if the text changed. Identifier `control.<key>`.
struct CommitTextField: View {
    let key: String
    let placeholder: String
    let value: String
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onSubmit { send() }
            .onChange(of: focused) { _, now in if !now { send() } }
            .accessibilityIdentifier("control.\(key)")
            .accessibilityLabel(placeholder)
    }

    private func send() {
        guard text != value else { return }
        commit(text)
    }
}

/// A row of mutually exclusive icon/label buttons (`control.<key>.<value>`), e.g. layout direction.
struct OptionRow: View {
    struct Option: Identifiable {
        let value: String
        let label: String
        var symbol: String?
        var id: String { value }
    }

    let key: String
    let options: [Option]
    let selected: String?
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let on = option.value == selected
                Button { action(option.value) } label: {
                    Group {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                        } else {
                            Text(verbatim: option.label).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityIdentifier("control.\(key).\(option.value)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// A menu picker (`control.<key>`) showing the current choice.
struct MenuPicker: View {
    let key: String
    let title: String
    let options: [OptionRow.Option]
    let selected: String?
    let action: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    action(option.value)
                } label: {
                    if option.value == selected { Label(option.label, systemImage: "checkmark") } else { Text(verbatim: option.label) }
                }
                .accessibilityIdentifier("control.\(key).\(option.value)")
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: options.first { $0.value == selected }?.label ?? (selected ?? "\u{2014}"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("control.\(key)")
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selected }?.label ?? (selected ?? ""))
    }
}

/// A labelled switch (`control.<key>`).
struct SwitchRow: View {
    let key: String
    let title: String
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { action($0) })) {
            Text(verbatim: title).font(.callout)
        }
        .accessibilityIdentifier("control.\(key)")
    }
}

/// Two or more fields on one row.
struct FieldRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }
    }
}

/// A small caption above a group of fields.
struct SubLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
