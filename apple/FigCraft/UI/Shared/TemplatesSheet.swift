import SwiftUI
@preconcurrency import FigCraftKit

/// Starter templates (`templates()`); choosing one runs `file.newFromTemplate`.
struct TemplatesSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    private let items: [TemplateInfo] = FigCraftKit.templates()

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.id) { template in
                    Button {
                        choose(template)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(verbatim: template.name).font(.body.weight(.medium))
                                Spacer()
                                Text(verbatim: template.size).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(verbatim: template.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(verbatim: template.kind.capitalized).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("template.\(template.id)")
                }
            }
            .accessibilityIdentifier("templates.list")
            .navigationTitle("New from Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                        .accessibilityIdentifier("templates.cancel")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("templates")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { model.showTemplates = false }
    }

    private func close() {
        model.showTemplates = false
        dismiss()
    }

    private func choose(_ template: TemplateInfo) {
        close()
        model.run("file.newFromTemplate", ["template": template.id])
    }
}
