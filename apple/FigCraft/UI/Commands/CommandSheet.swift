import SwiftUI
@preconcurrency import FigCraftKit

/// Generic parameter sheet for any engine command: the form is generated from the parsed params doc
/// (`CommandCatalog.params`). Read-only commands show their result instead of closing.
struct CommandSheet: View {
    let model: EditorModel
    let commandID: String

    @Environment(\.dismiss) private var dismiss
    @State private var form: CommandForm
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var showHelp = false

    init(model: EditorModel, commandID: String) {
        self.model = model
        self.commandID = commandID
        _form = State(initialValue: CommandForm(commandID: commandID, selection: model.state.selection))
    }

    private var info: CommandInfo? { CommandCatalog.shared.command(commandID) }
    private var title: String { info?.label ?? commandID }
    private var enabled: Bool { model.isEnabled(commandID) }
    private var disabledReason: String? { model.handle.disabledReason(id: commandID) }

    var body: some View {
        NavigationStack {
            Form {
                if !enabled, let reason = disabledReason {
                    Section {
                        Label { Text(verbatim: reason) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("cmdSheet.disabled")
                    }
                }
                if form.usesSelection {
                    Section {
                        Label("Applies to the current selection", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !form.fields.isEmpty {
                    Section("Parameters") {
                        ForEach(form.fields, id: \.key) { field in
                            CommandFieldRow(form: form, field: field)
                        }
                    }
                }
                if form.freeFormLabel != nil || (form.fields.isEmpty && !form.usesSelection) {
                    Section {
                        TextField("{ }", text: $form.freeJSON, axis: .vertical)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...8)
                            .accessibilityIdentifier("param.extra")
                    } header: {
                        Text("Extra parameters (JSON)")
                    } footer: {
                        if let label = form.freeFormLabel { Text(verbatim: label) }
                    }
                }
                if let errorText {
                    Section("Error") {
                        Text(verbatim: errorText).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("cmdSheet.error")
                    }
                }
                if let resultText {
                    Section("Result") {
                        Text(verbatim: resultText).font(.callout.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("cmdSheet.result")
                    }
                }
                if let doc = info?.params, !doc.isEmpty {
                    Section {
                        DisclosureGroup("Parameter reference", isExpanded: $showHelp) {
                            Text(verbatim: doc).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cmdSheet")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(resultText == nil ? "Cancel" : "Done") { close() }
                        .accessibilityIdentifier("cmdSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(!enabled || !form.canRun)
                        .accessibilityIdentifier("cmdSheet.run")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { if model.pendingCommand == commandID { model.pendingCommand = nil } }
    }

    private func close() {
        model.pendingCommand = nil
        dismiss()
    }

    private func apply() {
        errorText = nil
        let params: [String: Any]
        do {
            params = try form.params()
        } catch let e as CommandForm.FormError {
            errorText = e.message
            return
        } catch {
            errorText = error.localizedDescription
            return
        }
        model.lastError = nil
        let result = model.run(commandID, params)
        if let failure = model.lastError {
            // Keep the sheet open and show the engine's message here (an alert cannot stack on a sheet).
            errorText = failure
            model.lastError = nil
            return
        }
        if info?.undoable == false, let text = Self.resultText(of: result) {
            resultText = text
        } else {
            close()
        }
    }

    /// The pretty-printed result of a read-only command, nil when it carries nothing worth showing.
    private static func resultText(of result: Any?) -> String? {
        guard let result else { return nil }
        if let dict = result as? [String: Any] {
            if dict.isEmpty { return nil }
            if dict.count == 1, dict["ok"] != nil { return nil }
        }
        if result is NSNull { return nil }
        return CommandForm.pretty(result)
    }
}
