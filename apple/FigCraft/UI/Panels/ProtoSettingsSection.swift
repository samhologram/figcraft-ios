import SwiftUI
@preconcurrency import FigCraftKit

/// What the Prototype tab last set for a page. The engine does not report a page's prototype settings, so the UI
/// keeps the values it sent (starting from the engine defaults) per page for the session.
struct ProtoSettingsMirror: Equatable {
    var device = "None"
    var rotation = "portrait"
    var width = 1280.0
    var height = 720.0
    var responsive = false
    var background = "#1E1E1E"
}

/// Prototype settings (desktop `proto_panel.rs` `settings`), shown when nothing is selected: device, rotation,
/// custom size, responsive, background (`proto.settings`) and the present options (`proto.presentOptions`: scale,
/// device frame, hotspot hints, inspect). Identifiers `section.protoSettings`, `control.device`, ...
struct ProtoSettingsSection: View {
    let model: EditorModel

    @Environment(EditorUIState.self) private var ui: EditorUIState?
    @State private var local = ProtoSettingsMirror()

    @AppStorage("figcraft.present.scale") private var presentScale = "fit"
    @AppStorage("figcraft.present.deviceFrame") private var deviceFrame = true
    @AppStorage("figcraft.present.hotspotHints") private var hotspotHints = true
    @AppStorage("figcraft.present.inspect") private var presentInspect = false

    private static let devices: [String] = [
        "iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone Air", "iPhone 16", "iPhone 16 Pro", "iPhone 16 Pro Max",
        "iPhone 16 Plus", "iPhone 15 Pro", "iPhone 15 Pro Max", "iPhone 15 Plus", "iPhone 14 Pro", "iPhone 14 Pro Max",
        "iPhone 14", "Android Compact", "Android Medium", "iPad mini", "MacBook Air", "Desktop",
    ]
    private static let custom = "Custom size"
    /// Devices that do not turn.
    private static let fixed: Set<String> = ["None", "Custom size", "MacBook Air", "Desktop"]

    private static let rotations: [OptionRow.Option] = [
        .init(value: "portrait", label: "Portrait", symbol: "rectangle.portrait"),
        .init(value: "landscape", label: "Landscape", symbol: "rectangle"),
    ]
    private static let scales: [OptionRow.Option] = [
        .init(value: "fit", label: "Fit"), .init(value: "fitWidth", label: "Fit width"),
        .init(value: "fill", label: "Fill"), .init(value: "actual", label: "Actual size"),
    ]

    private var page: UInt64 { model.state.page }
    private var settings: ProtoSettingsMirror { ui?.protoMirrors[page] ?? local }

    private func remember(_ change: (inout ProtoSettingsMirror) -> Void) {
        var next = settings
        change(&next)
        if let ui { ui.protoMirrors[page] = next } else { local = next }
    }

    private var deviceOptions: [OptionRow.Option] {
        var options: [OptionRow.Option] = [.init(value: "None", label: "None")]
        options.append(contentsOf: Self.devices.map { OptionRow.Option(value: $0, label: $0) })
        options.append(.init(value: Self.custom, label: Self.custom))
        return options
    }

    var body: some View {
        let s = settings
        InspectorSection("protoSettings", title: "Prototype settings") {
            VStack(alignment: .leading, spacing: 10) {
                SubLabel("Device")
                MenuPicker(key: "device", title: "", options: deviceOptions, selected: s.device) { value in
                    remember { $0.device = value }
                    model.run("proto.settings", ["device": value])
                }
                if !Self.fixed.contains(s.device) {
                    OptionRow(key: "rotation", options: Self.rotations, selected: s.rotation) { value in
                        remember { $0.rotation = value }
                        model.run("proto.settings", ["rotation": value])
                    }
                }
                if s.device == Self.custom { customSize(s) }
                SwitchRow(key: "responsive", title: "Responsive", isOn: s.responsive) { on in
                    remember { $0.responsive = on }
                    model.run("proto.settings", ["responsive": on])
                }
                SubLabel("Background")
                HStack(spacing: 10) {
                    PaintSwatch(hex: s.background) { hex in setBackground(hex) }
                        .frame(width: 34)
                    CommitTextField(key: "protoBackground", placeholder: "#RRGGBB", value: s.background.uppercased()) { text in
                        setBackground(text)
                    }
                }
                presentOptions
            }
        }
    }

    private func customSize(_ s: ProtoSettingsMirror) -> some View {
        FieldRow {
            ScrubField(model: model, key: "protoWidth", label: "W", value: s.width, range: 1...10_000, decimals: 0) { v in
                remember { $0.width = v }
                model.run("proto.settings", ["width": v])
            }
            ScrubField(model: model, key: "protoHeight", label: "H", value: s.height, range: 1...10_000, decimals: 0) { v in
                remember { $0.height = v }
                model.run("proto.settings", ["height": v])
            }
        }
    }

    private func setBackground(_ text: String) {
        guard let parsed = EngineColor.parse(text) else {
            model.showToast("Invalid color")
            return
        }
        remember { $0.background = parsed.hex }
        model.run("proto.settings", ["background": parsed.hex])
    }

    // MARK: Present options

    @ViewBuilder
    private var presentOptions: some View {
        SubLabel("Present options")
        MenuPicker(key: "presentScale", title: "Scale", options: Self.scales, selected: presentScale) { value in
            presentScale = value
            sendPresentOptions(["scale": value])
        }
        SwitchRow(key: "presentDeviceFrame", title: "Show device frame", isOn: deviceFrame) { on in
            deviceFrame = on
            sendPresentOptions(["deviceFrame": on])
        }
        SwitchRow(key: "presentHotspotHints", title: "Hotspot hints", isOn: hotspotHints) { on in
            hotspotHints = on
            sendPresentOptions(["hotspotHints": on])
        }
        SwitchRow(key: "presentInspect", title: "Inspect while presenting", isOn: presentInspect) { on in
            presentInspect = on
            sendPresentOptions(["inspect": on])
        }
    }

    /// The engine keeps them for later presentations and answers with a `present.options` UI request (no iOS
    /// counterpart), so the call is quiet; the values are also kept in the app's defaults.
    private func sendPresentOptions(_ params: [String: Any]) {
        model.runQuiet("proto.presentOptions", params)
    }
}
