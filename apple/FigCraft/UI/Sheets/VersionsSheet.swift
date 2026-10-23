import SwiftUI
@preconcurrency import FigCraftKit

/// Version history of the file, newest first: save a named version, preview one on the canvas, restore it (one undo
/// step), rename or delete it. Engine commands: `version.list` (query), `file.saveVersion`, `version.preview`,
/// `version.exitPreview`, `version.restore`, `version.rename`, `version.delete`. Identifier `versions`.
struct VersionsSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    private struct VersionItem: Identifiable {
        let id: String
        let name: String
        let note: String
        let time: Double
        let auto: Bool
        let previewing: Bool
    }

    @State private var versions: [VersionItem] = []
    @State private var request: NameRequest?
    @State private var confirmRestore: VersionItem?

    private var previewing: VersionItem? { versions.first { $0.previewing } }

    var body: some View {
        NavigationStack {
            List {
                if let previewing {
                    HStack {
                        Label("Viewing \(previewing.name)", systemImage: "eye")
                            .font(.callout)
                        Spacer(minLength: 8)
                        Button("Back to current") {
                            model.run("version.exitPreview")
                            reload()
                        }
                        .accessibilityIdentifier("versions.exitPreview")
                    }
                    .listRowBackground(Color.accentColor.opacity(0.12))
                    .accessibilityIdentifier("versions.previewBanner")
                }
                if versions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No versions yet.").font(.callout).foregroundStyle(.secondary)
                        Text("Save a version to be able to come back to this state.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("versions.empty")
                }
                ForEach(versions) { version in versionRow(version) }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("versions.list")
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        request = NameRequest(kind: "save", title: "Save version", initial: "Version \(versions.count + 1)",
                                              confirmLabel: "Save")
                    } label: {
                        Label("Save version", systemImage: "plus")
                    }
                    .accessibilityIdentifier("versions.save")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("versions.done")
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: model.state.revision) { _, _ in reload() }
        .namePrompt($request) { request, text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            switch request.kind {
            case "save":
                model.run("file.saveVersion", ["name": name])
            case "rename":
                model.run("version.rename", ["id": request.target, "name": name])
            default:
                break
            }
            reload()
        }
        .confirmationDialog("Restore this version?", isPresented: Binding(
            get: { confirmRestore != nil },
            set: { if !$0 { confirmRestore = nil } }
        ), titleVisibility: .visible) {
            Button("Restore") {
                if let version = confirmRestore {
                    model.run("version.restore", ["id": version.id])
                    reload()
                    dismiss()
                }
                confirmRestore = nil
            }
            .accessibilityIdentifier("versions.restoreConfirm")
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("The design is replaced by \(confirmRestore?.name ?? "this version"). The current design is kept in the history and you can undo.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versions")
    }

    private func versionRow(_ version: VersionItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: version.name).font(.body.weight(.medium)).lineLimit(1)
                    if version.auto {
                        Text("Auto")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(verbatim: Self.time(version.time)).font(.caption).foregroundStyle(.secondary)
                if !version.note.isEmpty {
                    Text(verbatim: version.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            IconButton(symbol: "eye", label: "Preview \(version.name)", identifier: "version.\(version.id).preview") {
                model.run("version.preview", ["id": version.id])
                reload()
            }
            Button("Restore") { confirmRestore = version }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.isEnabled("version.restore"))
                .accessibilityIdentifier("version.\(version.id).restore")
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.run("version.delete", ["id": version.id])
                reload()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("version.\(version.id).delete")
        }
        .contextMenu {
            Button("Preview", systemImage: "eye") {
                model.run("version.preview", ["id": version.id])
                reload()
            }
            Button("Rename\u{2026}", systemImage: "pencil") {
                request = NameRequest(kind: "rename", title: "Rename version", initial: version.name, target: version.id,
                                      confirmLabel: "Rename")
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.run("version.delete", ["id": version.id])
                reload()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version.\(version.id)")
    }

    // MARK: Engine

    private func reload() {
        let list = (model.query("version.list") as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        // The engine lists the oldest first.
        versions = list.reversed().compactMap { item -> VersionItem? in
            guard let id = item.string("id") else { return nil }
            return VersionItem(id: id, name: item.string("name") ?? "Version", note: item.string("description") ?? "",
                               time: item.number("time") ?? 0, auto: item.bool("auto") ?? false,
                               previewing: item.bool("previewing") ?? false)
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
}
