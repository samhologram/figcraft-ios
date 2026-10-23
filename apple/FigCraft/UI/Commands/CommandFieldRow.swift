import SwiftUI
@preconcurrency import FigCraftKit

/// One row of the generic parameter form, for one `ParamField`.
struct CommandFieldRow: View {
    @Bindable var form: CommandForm
    let field: ParamField

    private var key: String { field.key }
    private var includedBinding: Binding<Bool> {
        Binding(
            get: { form.included.contains(key) },
            set: { if $0 { form.included.insert(key) } else { form.included.remove(key) } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.isOptional {
                Toggle(isOn: includedBinding) { Text(verbatim: field.label) }
                    .accessibilityIdentifier("param.\(key).enabled")
                if form.included.contains(key) { control }
            } else {
                if field.kind != "bool" {
                    Text(verbatim: field.label).font(.subheadline.weight(.medium))
                }
                control
            }
            if !field.doc.isEmpty {
                Text(verbatim: field.doc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { form.texts[key] ?? "" }, set: { form.texts[key] = $0 })
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case "number", "integer": numberControl
        case "bool":
            Toggle(isOn: Binding(get: { form.flags[key] ?? false }, set: { form.flags[key] = $0 })) {
                Text(verbatim: field.isOptional ? "Value" : field.label)
            }
            .accessibilityIdentifier("param.\(key)")
        case "choice":
            if field.choices.count <= 4 {
                Picker(selection: text(key)) {
                    ForEach(field.choices, id: \.self) { c in Text(verbatim: c).tag(c) }
                } label: { Text(verbatim: field.label) }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("param.\(key)")
            } else {
                Picker(selection: text(key)) {
                    ForEach(field.choices, id: \.self) { c in Text(verbatim: c).tag(c) }
                } label: { Text(verbatim: field.label) }
                .pickerStyle(.menu)
                .accessibilityIdentifier("param.\(key)")
            }
        case "color":
            HStack {
                ColorPicker("", selection: Binding(
                    get: { Color(hex: form.texts[key] ?? "") ?? .black },
                    set: { form.texts[key] = $0.hexString() }
                ), supportsOpacity: false)
                .labelsHidden()
                TextField("#RRGGBB", text: text(key))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("param.\(key)")
            }
        case "json":
            TextField("JSON", text: text(key), axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...8)
                .accessibilityIdentifier("param.\(key)")
        case "id":
            TextField(field.kind == "id" ? "Layer id" : field.label, text: text(key))
                .keyboardType(.numberPad)
                .accessibilityIdentifier("param.\(key)")
        default:
            TextField(field.label, text: text(key))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("param.\(key)")
        }
    }

    private var isInteger: Bool { field.kind == "integer" }

    private var numberBinding: Binding<Double> {
        Binding(get: { form.numbers[key] ?? 0 }, set: { form.numbers[key] = $0.isFinite ? $0 : 0 })
    }

    @ViewBuilder
    private var numberControl: some View {
        if let lo = field.min, let hi = field.max, hi > lo, lo.isFinite, hi.isFinite {
            HStack {
                Slider(value: numberBinding, in: lo...hi, step: isInteger ? 1 : (hi - lo) / 200)
                    .accessibilityIdentifier("param.\(key)")
                Text(verbatim: Humanize.number(form.numbers[key] ?? 0, decimals: isInteger ? 0 : 2))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        } else {
            HStack {
                TextField(field.label, value: numberBinding, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("param.\(key)")
                Stepper("", value: numberBinding, step: isInteger ? 1 : 0.1)
                    .labelsHidden()
            }
        }
    }
}
