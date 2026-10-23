import SwiftUI
@preconcurrency import FigCraftKit

/// Searchable list of every engine command that works on iOS. Disabled commands are greyed with the engine's
/// reason; choosing one closes the palette and runs it (or opens its parameter sheet).
struct CommandPaletteView: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct PaletteGroup: Identifiable {
        let title: String
        let rows: [CommandInfo]
        var id: String { title }
    }

    @MainActor private static let entries: [CommandInfo] = CommandCatalog.shared.commands.filter { !CommandCatalog.shared.isExcluded($0.id) }

    private var tokens: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var results: [CommandInfo] {
        let terms = tokens
        guard !terms.isEmpty else { return [] }
        var scored: [(entry: CommandInfo, score: Int)] = []
        for e in Self.entries {
            let label = e.label.lowercased()
            let path = e.menu.joined(separator: " ").lowercased()
            let id = e.id.lowercased()
            var score = 0
            var matched = true
            for t in terms {
                if label.hasPrefix(t) { score += 40 }
                else if label.contains(" " + t) { score += 30 }
                else if label.contains(t) { score += 20 }
                else if path.contains(t) { score += 10 }
                else if id.contains(t) { score += 5 }
                else { matched = false; break }
            }
            if matched { scored.append((e, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.label < $1.entry.label }
        return scored.prefix(200).map(\.entry)
    }

    private var groups: [PaletteGroup] {
        var order: [String] = []
        var buckets: [String: [CommandInfo]] = [:]
        for e in Self.entries {
            let title = e.menu.first ?? "Other commands"
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(e)
        }
        let menuOrder = CommandCatalog.shared.menus.map(\.title)
        let known = menuOrder.filter { buckets[$0] != nil }
        let rest = order.filter { !menuOrder.contains($0) }
        return (known + rest).map { PaletteGroup(title: $0, rows: buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commands", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .accessibilityIdentifier("palette.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                            .accessibilityIdentifier("palette.clear")
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)

                List {
                    if tokens.isEmpty {
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.rows, id: \.id) { row in PaletteRow(model: model, entry: row) { choose(row) } }
                            }
                        }
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ForEach(results, id: \.id) { row in PaletteRow(model: model, entry: row) { choose(row) } }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("palette.list")
            }
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                        .accessibilityIdentifier("palette.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { model.showCommandPalette = false }
    }

    private func close() {
        model.showCommandPalette = false
        dismiss()
    }

    /// Close the palette, then (once its dismissal finished) invoke the command: presenting its parameter sheet
    /// straight away would collide with the dismissal.
    private func choose(_ entry: CommandInfo) {
        let model = model
        let id = entry.id
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            model.present(id)
        }
    }
}

private struct PaletteRow: View {
    let model: EditorModel
    let entry: CommandInfo
    let action: () -> Void

    var body: some View {
        let reason = model.handle.disabledReason(id: entry.id)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.label)
                        .foregroundStyle(reason == nil ? Color.primary : Color.secondary)
                    Text(verbatim: entry.menu.isEmpty ? entry.id : entry.menu.joined(separator: " \u{203A} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reason {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut = entry.shortcut {
                    Text(verbatim: CommandCatalog.display(shortcut))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(reason != nil)
        .accessibilityIdentifier("command.\(entry.id)")
    }
}
