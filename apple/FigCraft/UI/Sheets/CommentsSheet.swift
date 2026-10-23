import SwiftUI
@preconcurrency import FigCraftKit

/// The comment threads of the file. Filter (all / open / resolved, this page or every page), add a comment at the
/// centre of the canvas, reply, resolve or reopen, go to a thread, delete. Engine commands: `comment.list` (query),
/// `comment.add`, `comment.reply`, `comment.resolve`, `comment.open`, `comment.delete`. Identifier `comments`.
struct CommentsSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    private struct CommentThread: Identifiable {
        let id: UInt64
        let author: String
        let text: String
        let created: Double
        let resolved: Bool
        let unread: Bool
        let pageName: String
        let replies: [Message]
    }

    private struct Message: Identifiable {
        let id: Int
        let author: String
        let text: String
        let created: Double
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all, open, resolved
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    @State private var threads: [CommentThread] = []
    @State private var filter: Filter = .all
    @State private var allPages = false
    @State private var draft = ""
    @State private var replyTarget: UInt64?
    @State private var replyText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(verbatim: f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("comments.filter")
                list
                composer
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $allPages) { Text("All pages") }
                        .toggleStyle(.button)
                        .accessibilityIdentifier("comments.allPages")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("comments.done")
                }
            }
        }
        .onChange(of: filter, initial: true) { _, _ in reload() }
        .onChange(of: allPages) { _, _ in reload() }
        .onChange(of: model.state.revision) { _, _ in reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comments")
    }

    // MARK: List

    private var list: some View {
        List {
            if threads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(filter == .all ? "No comments yet." : "No \(filter.rawValue) comments.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("comments.empty")
            }
            ForEach(threads) { thread in threadRow(thread) }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("comments.list")
    }

    private func threadRow(_ thread: CommentThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if thread.unread { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
                Text(verbatim: thread.author).font(.subheadline.weight(.semibold))
                Text(verbatim: Self.time(thread.created)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if thread.resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(verbatim: thread.text).font(.callout)
            if allPages, !thread.pageName.isEmpty {
                Text(verbatim: thread.pageName).font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(thread.replies) { reply in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: reply.author).font(.caption.weight(.semibold))
                        Text(verbatim: Self.time(reply.created)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(verbatim: reply.text).font(.footnote)
                }
                .padding(.leading, 14)
            }
            if replyTarget == thread.id {
                HStack(spacing: 6) {
                    TextField("Reply", text: $replyText)
                        .padding(8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { sendReply(thread) }
                        .accessibilityIdentifier("comment.\(thread.id).replyField")
                    Button { sendReply(thread) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send reply")
                    .accessibilityIdentifier("comment.\(thread.id).replySend")
                }
            }
            HStack(spacing: 14) {
                actionButton("Reply", "arrowshape.turn.up.left", "comment.\(thread.id).reply") {
                    replyText = ""
                    replyTarget = replyTarget == thread.id ? nil : thread.id
                }
                actionButton(thread.resolved ? "Reopen" : "Resolve", thread.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle",
                             "comment.\(thread.id).resolve") {
                    model.run("comment.resolve", ["id": thread.id, "resolved": !thread.resolved])
                    reload()
                }
                actionButton("Go to", "scope", "comment.\(thread.id).open") {
                    model.runQuiet("comment.open", ["id": thread.id])
                    dismiss()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .opacity(thread.resolved ? 0.7 : 1)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.run("comment.delete", ["id": thread.id])
                reload()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("comment.\(thread.id).delete")
        }
        .contextMenu {
            Button("Delete thread", systemImage: "trash", role: .destructive) {
                model.run("comment.delete", ["id": thread.id])
                reload()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comment.\(thread.id)")
    }

    private func actionButton(_ title: String, _ symbol: String, _ identifier: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Add a comment at the center of the canvas", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("comments.field")
            Button { add() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add comment")
            .accessibilityIdentifier("comments.add")
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: Engine

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let x = model.state.centerX.isFinite ? model.state.centerX : 0
        let y = model.state.centerY.isFinite ? model.state.centerY : 0
        model.run("comment.add", ["x": x, "y": y, "text": text, "anchor": true])
        draft = ""
        composerFocused = false
        reload()
    }

    private func sendReply(_ thread: CommentThread) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.run("comment.reply", ["id": thread.id, "text": text])
        replyText = ""
        replyTarget = nil
        reload()
    }

    private func reload() {
        var params: [String: Any] = ["filter": filter.rawValue]
        if allPages { params["page"] = "all" }
        let list = (model.query("comment.list", params) as? JSONObject)?.objects("comments") ?? []
        threads = list.compactMap { item -> CommentThread? in
            guard let id = item.number("id")?.asID else { return nil }
            let replies = item.objects("replies").enumerated().map { index, reply in
                Message(id: index, author: reply.string("author") ?? "", text: reply.string("text") ?? "",
                        created: reply.number("created") ?? 0)
            }
            return CommentThread(id: id, author: item.string("author") ?? "", text: item.string("text") ?? "",
                          created: item.number("created") ?? 0, resolved: item.bool("resolved") ?? false,
                          unread: item.bool("unread") ?? false, pageName: item.string("pageName") ?? "", replies: replies)
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
}
