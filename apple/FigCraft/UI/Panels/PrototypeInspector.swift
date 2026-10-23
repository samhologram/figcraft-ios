import SwiftUI
@preconcurrency import FigCraftKit

/// The Prototype tab (`proto_panel.rs`): flow starting points of the page (nothing selected) or of the selected
/// top-level frame, and the interactions of the selected layer (trigger, action, destination, transition).
struct PrototypeInspector: View {
    let model: EditorModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.state.selection.isEmpty {
                    FlowsSection(model: model, frame: nil)
                    Divider()
                    ProtoSettingsSection(model: model)
                } else if let json = model.selectionJSON, let id = model.state.selection.first {
                    if let row = model.layers.first(where: { $0.id == id }), row.parent == nil, row.kind == "frame" {
                        FlowsSection(model: model, frame: id)
                        Divider()
                    }
                    InteractionsSection(model: model, layer: id, json: json)
                } else {
                    InspectorSection("interactions", title: "Interactions") {
                        Text("Select a single layer to edit its interactions.")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("prototype.scroll")
    }
}

// MARK: Flows

private struct Flow: Identifiable {
    let start: UInt64
    let name: String
    let description: String
    var id: UInt64 { start }
}

private struct FlowsSection: View {
    let model: EditorModel
    /// A selected top-level frame, or nil for the page overview.
    let frame: UInt64?

    private var flows: [Flow] {
        (model.nodeObject(model.state.page)?.objects("flows") ?? []).compactMap { f in
            guard let start = f.number("start") else { return nil }
            return Flow(start: UInt64(max(0, start)), name: f.string("name") ?? "Flow", description: f.string("description") ?? "")
        }
    }

    var body: some View {
        let all = flows
        let shown = frame.map { f in all.filter { $0.start == f } } ?? all
        InspectorSection("flows", title: frame == nil ? "Flow starting points" : "Flow starting point") {
            if frame == nil || shown.isEmpty {
                IconButton(symbol: "plus", label: "Add starting point", identifier: "command.proto.flow.add") { add(all) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if shown.isEmpty {
                    Text(frame == nil ? "Select a frame and add a starting point to present it as a flow."
                                      : "This frame is not a flow starting point yet.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
                ForEach(shown) { flow in flowRow(flow) }
                if let frame, shown.isEmpty {
                    Button { model.startPresenting(from: frame) } label: {
                        Label("Preview this frame", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flow.preview")
                }
            }
        }
    }

    private func add(_ all: [Flow]) {
        if let frame {
            model.run("proto.flow.add", ["start": frame])
            return
        }
        let taken = Set(all.map(\.start))
        if let free = model.layers.first(where: { $0.parent == nil && $0.kind == "frame" && !taken.contains($0.id) }) {
            model.run("proto.flow.add", ["start": free.id])
        } else {
            model.showToast("Every top-level frame already starts a flow")
        }
    }

    private func flowRow(_ flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconButton(symbol: "play.fill", label: "Play \(flow.name)", identifier: "flow.\(flow.start).play") {
                    model.startPresenting(from: flow.start)
                }
                CommitTextField(key: "flow.\(flow.start).name", placeholder: "Flow name", value: flow.name) { name in
                    model.run("proto.flow.rename", ["start": flow.start, "name": name])
                }
                IconButton(symbol: "minus", label: "Remove flow", identifier: "command.proto.flow.remove") {
                    model.run("proto.flow.remove", ["start": flow.start])
                }
            }
            if let frameName = model.layers.first(where: { $0.id == flow.start })?.name {
                Text(verbatim: "Starts at \(frameName)").font(.caption).foregroundStyle(.secondary).padding(.leading, 40)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.\(flow.start)")
    }
}

// MARK: Interactions

private enum Proto {
    static let triggers: [OptionRow.Option] = [
        .init(value: "onClick", label: "On click"), .init(value: "onDrag", label: "On drag"),
        .init(value: "onHover", label: "While hovering"), .init(value: "onPress", label: "While pressing"),
        .init(value: "keyPress", label: "Key/Gamepad"), .init(value: "mouseEnter", label: "Mouse enter"),
        .init(value: "mouseLeave", label: "Mouse leave"), .init(value: "mouseDown", label: "Mouse down"),
        .init(value: "mouseUp", label: "Mouse up"), .init(value: "afterDelay", label: "After delay"),
    ]
    static let actions: [OptionRow.Option] = [
        .init(value: "navigate", label: "Navigate to"), .init(value: "back", label: "Back"),
        .init(value: "scrollTo", label: "Scroll to"), .init(value: "openOverlay", label: "Open overlay"),
        .init(value: "swapOverlay", label: "Swap overlay"), .init(value: "closeOverlay", label: "Close overlay"),
        .init(value: "openUrl", label: "Open link"), .init(value: "changeTo", label: "Change to"),
    ]
    static let transitions: [OptionRow.Option] = [
        .init(value: "instant", label: "Instant"), .init(value: "dissolve", label: "Dissolve"),
        .init(value: "smartAnimate", label: "Smart animate"), .init(value: "moveIn", label: "Move in"),
        .init(value: "moveOut", label: "Move out"), .init(value: "push", label: "Push"),
        .init(value: "slideIn", label: "Slide in"), .init(value: "slideOut", label: "Slide out"),
    ]
    static let directions: [OptionRow.Option] = [
        .init(value: "left", label: "Left"), .init(value: "right", label: "Right"),
        .init(value: "top", label: "Top"), .init(value: "bottom", label: "Bottom"),
    ]
    static let directional: Set<String> = ["moveIn", "moveOut", "push", "slideIn", "slideOut"]
    static let needsDestination: Set<String> = ["navigate", "scrollTo", "openOverlay", "swapOverlay", "changeTo"]
    static let animated: Set<String> = ["navigate", "openOverlay", "swapOverlay", "closeOverlay", "changeTo", "back"]

    static func label(_ options: [OptionRow.Option], _ value: String?) -> String {
        options.first { $0.value == value }?.label ?? Humanize.key(value ?? "")
    }
}

private struct InteractionsSection: View {
    let model: EditorModel
    let layer: UInt64
    let json: JSONObject

    var body: some View {
        let list = json.objects("interactions")
        InspectorSection("interactions", title: "Interactions") {
            IconButton(symbol: "plus", label: "Add interaction", identifier: "command.proto.interaction.add") { add() }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if list.isEmpty {
                    Text("No interactions. Add one to make this layer react when the prototype plays.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { index, interaction in
                    InteractionCard(model: model, layer: layer, index: index, interaction: interaction)
                }
            }
        }
    }

    /// Click, then navigate to the next frame (Back when there is nowhere to go), as the desktop's plus does.
    private func add() {
        let own = model.layers.first(where: { $0.id == layer })
        let target = model.navigationFrames.first { $0.id != layer && $0.id != own?.parent }
        let action: [String: Any] = target.map { ["type": "navigate", "dest": $0.id] } ?? ["type": "back"]
        model.run("proto.interaction.add", ["id": layer, "trigger": ["type": "onClick"], "action": action])
    }
}

private struct InteractionCard: View {
    let model: EditorModel
    let layer: UInt64
    let index: Int
    let interaction: JSONObject

    private var trigger: JSONObject { interaction.object("trigger") ?? ["type": "onClick"] }
    private var action: JSONObject { interaction.objects("actions").first ?? ["type": "back"] }
    private var transition: JSONObject { interaction.object("transition") ?? ["type": "instant"] }
    private var triggerType: String { trigger.string("type") ?? "onClick" }
    private var actionType: String { action.string("type") ?? "back" }
    private var transitionType: String { transition.string("type") ?? "instant" }
    private var duration: Double { interaction.number("durationMs") ?? interaction.number("duration_ms") ?? 300 }

    private var destinations: [OptionRow.Option] {
        model.navigationFrames.map { .init(value: String($0.id), label: $0.name) }
    }

    private func set(_ fields: [String: Any]) {
        var params = fields
        params["id"] = layer
        params["index"] = index
        model.run("proto.interaction.set", params)
    }

    private func destName(_ value: Any?) -> String {
        guard let n = value as? NSNumber else { return "\u{2014}" }
        return model.layers.first { $0.id == n.uint64Value }?.name ?? "Layer \(n.uint64Value)"
    }

    private var summary: String {
        var s = Proto.label(Proto.actions, actionType)
        if Proto.needsDestination.contains(actionType) { s += " \(destName(action["dest"]))" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Proto.label(Proto.triggers, triggerType)).font(.callout.weight(.semibold))
                    Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                IconButton(symbol: "minus", label: "Remove interaction", identifier: "command.proto.interaction.remove") {
                    model.run("proto.interaction.remove", ["id": layer, "index": index])
                }
            }
            MenuPicker(key: "interaction.\(index).trigger", title: "Trigger", options: Proto.triggers, selected: triggerType) { v in
                var t: [String: Any] = ["type": v]
                if v == "afterDelay" { t["ms"] = trigger.number("ms") ?? 800 }
                if v == "keyPress" { t["key"] = trigger.string("key").flatMap { $0.isEmpty ? nil : $0 } ?? "Space" }
                set(["trigger": t])
            }
            if triggerType == "afterDelay" {
                ScrubField(model: model, key: "interaction.\(index).delay", label: "Delay", value: trigger.number("ms") ?? 800, unit: "ms",
                           step: 10, range: 0...600_000, decimals: 0) { v in
                    set(["trigger": ["type": "afterDelay", "ms": Int(v.rounded())]])
                }
            }
            if triggerType == "keyPress" {
                CommitTextField(key: "interaction.\(index).key", placeholder: "Key (e.g. Space, Shift+K)", value: trigger.string("key") ?? "") { text in
                    set(["trigger": ["type": "keyPress", "key": text]])
                }
            }
            MenuPicker(key: "interaction.\(index).action", title: "Action", options: Proto.actions, selected: actionType) { v in
                var a: [String: Any] = ["type": v]
                if Proto.needsDestination.contains(v) {
                    let fallback = model.navigationFrames.first { $0.id != layer }
                    if let dest = (action["dest"] as? NSNumber)?.uint64Value ?? fallback?.id { a["dest"] = dest }
                }
                if v == "openUrl" { a["url"] = action.string("url") ?? "https://" }
                set(["action": a])
            }
            if Proto.needsDestination.contains(actionType) {
                MenuPicker(key: "interaction.\(index).dest", title: "To", options: destinations,
                           selected: (action["dest"] as? NSNumber).map { String($0.uint64Value) }) { v in
                    guard let dest = UInt64(v) else { return }
                    var a = action
                    a["dest"] = dest
                    set(["action": a])
                }
            }
            if actionType == "openUrl" {
                CommitTextField(key: "interaction.\(index).url", placeholder: "https://", value: action.string("url") ?? "") { text in
                    var a = action
                    a["url"] = text
                    set(["action": a])
                }
            }
            if Proto.animated.contains(actionType) {
                MenuPicker(key: "interaction.\(index).transition", title: "Animation", options: Proto.transitions, selected: transitionType) { v in
                    var t: [String: Any] = ["type": v]
                    if Proto.directional.contains(v) { t["direction"] = transition.string("direction") ?? "left" }
                    set(["transition": t])
                }
                if Proto.directional.contains(transitionType) {
                    OptionRow(key: "interaction.\(index).direction", options: Proto.directions, selected: transition.string("direction") ?? "left") { v in
                        set(["transition": ["type": transitionType, "direction": v]])
                    }
                }
                if transitionType != "instant" {
                    ScrubField(model: model, key: "interaction.\(index).duration", label: "Duration", value: duration, unit: "ms",
                               step: 5, range: 0...10_000, decimals: 0) { v in
                        set(["durationMs": Int(v.rounded())])
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("interaction.\(index)")
    }
}
