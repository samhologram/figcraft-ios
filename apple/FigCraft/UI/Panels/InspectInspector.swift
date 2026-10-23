import SwiftUI
@preconcurrency import FigCraftKit

/// The Inspect tab: read-only CSS-like properties (`inspect.properties`) and generated code (`inspect.code`)
/// of the selected layer, both engine queries.
struct InspectInspector: View {
    let model: EditorModel

    private static let languages: [OptionRow.Option] = [
        .init(value: "css", label: "CSS"), .init(value: "html", label: "HTML + CSS"), .init(value: "react", label: "React"),
        .init(value: "leptos", label: "Leptos"), .init(value: "swiftui", label: "SwiftUI"), .init(value: "compose", label: "Compose"),
    ]

    @State private var language = "css"
    @State private var showCode = false

    private var layerID: UInt64? { model.state.selection.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let id = layerID {
                    properties(id)
                    Divider()
                    InspectorSection("code", title: "Code") {
                        VStack(alignment: .leading, spacing: 8) {
                            MenuPicker(key: "codeLanguage", title: "Language", options: Self.languages, selected: language) { language = $0 }
                            Button {
                                showCode.toggle()
                            } label: {
                                Label(showCode ? "Hide code" : "Show code", systemImage: "curlybraces")
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("inspectCode.toggle")
                            if showCode { code(id) }
                        }
                    }
                } else {
                    InspectorSection("properties", title: "Properties") {
                        Text("Select a layer to inspect its properties.").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("inspect.scroll")
    }

    @ViewBuilder
    private func properties(_ id: UInt64) -> some View {
        let sections = (model.query("inspect.properties", ["id": id]) as? JSONObject)?.objects("sections") ?? []
        if sections.isEmpty {
            InspectorSection("properties", title: "Properties") {
                Text("No properties.").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            InspectorSection(index == 0 ? "properties" : "properties.\(index)", title: section.string("title") ?? "Properties") {
                VStack(spacing: 6) {
                    ForEach(Array(section.objects("rows").enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: row.string("label") ?? "").font(.callout).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if let hex = row.string("color"), let color = Color(hex: hex) {
                                Circle().fill(color).frame(width: 14, height: 14).overlay(Circle().stroke(.quaternary))
                            }
                            Text(verbatim: row.string("value") ?? "").font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                }
            }
            Divider()
        }
    }

    private func code(_ id: UInt64) -> some View {
        let result = model.query("inspect.code", ["id": id, "language": language]) as? JSONObject
        return Text(verbatim: result?.string("code") ?? "No code for this layer.")
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("inspectCode.text")
    }
}
