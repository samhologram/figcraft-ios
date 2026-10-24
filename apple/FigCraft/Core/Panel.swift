import Foundation
import Observation

/// iPad sidebar (iPhone sheet) panels. Raw values are the `panel.<rawValue>` accessibility identifiers.
enum LeftPanel: String, CaseIterable, Sendable {
    case layers, assets
}

/// Inspector tabs. Raw values are the `panel.<rawValue>` accessibility identifiers.
enum RightPanel: String, CaseIterable, Sendable {
    case design, prototype, inspect
}

enum DockPanelID: String, CaseIterable, Codable, Identifiable {
    case layers, assets, design, prototype, inspect
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var isLeading: Bool { self == .layers || self == .assets }
}

struct PanelDockGroup: Codable, Identifiable {
    var id: UUID = UUID()
    var tabs: [DockPanelID]
    var selected: DockPanelID
    var collapsed = false
}

/// Device-local panel arrangement. Each column may hold several stacked, reorderable tab groups.
@MainActor @Observable final class PanelDockLayout {
    var leading: [PanelDockGroup] = [] { didSet { save() } }
    var trailing: [PanelDockGroup] = [] { didSet { save() } }
    var lastShown: DockPanelID?
    var lastShownLeading: DockPanelID = .layers { didSet { UserDefaults.standard.set(lastShownLeading.rawValue, forKey: leadingSelectionKey) } }
    var lastShownTrailing: DockPanelID = .design { didSet { UserDefaults.standard.set(lastShownTrailing.rawValue, forKey: trailingSelectionKey) } }
    @ObservationIgnored private let key = "figcraft.panelDock.v1"
    @ObservationIgnored private let leadingSelectionKey = "figcraft.panelDock.selectedLeading"
    @ObservationIgnored private let trailingSelectionKey = "figcraft.panelDock.selectedTrailing"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([[PanelDockGroup]].self, from: data), stored.count == 2 {
            leading = stored[0]
            trailing = stored[1]
        } else {
            reset()
        }
        if let raw = UserDefaults.standard.string(forKey: leadingSelectionKey),
           let panel = DockPanelID(rawValue: raw), isVisible(panel) { lastShownLeading = panel }
        if let raw = UserDefaults.standard.string(forKey: trailingSelectionKey),
           let panel = DockPanelID(rawValue: raw), isVisible(panel) { lastShownTrailing = panel }
    }

    func reset() {
        leading = [PanelDockGroup(tabs: [.layers, .assets], selected: .layers)]
        trailing = [PanelDockGroup(tabs: [.design, .prototype, .inspect], selected: .design)]
        lastShownLeading = .layers
        lastShownTrailing = .design
    }

    func show(_ panel: DockPanelID) {
        var groups = panel.isLeading ? leading : trailing
        if let index = groups.firstIndex(where: { $0.tabs.contains(panel) }) {
            groups[index].selected = panel
            groups[index].collapsed = false
        } else {
            groups.append(PanelDockGroup(tabs: [panel], selected: panel))
        }
        set(groups, leading: panel.isLeading)
        lastShown = panel
        if panel.isLeading { lastShownLeading = panel } else { lastShownTrailing = panel }
    }

    func hide(_ panel: DockPanelID) {
        var groups = panel.isLeading ? leading : trailing
        guard let index = groups.firstIndex(where: { $0.tabs.contains(panel) }) else { return }
        let wasLastShown = panel == (panel.isLeading ? lastShownLeading : lastShownTrailing)
        groups[index].tabs.removeAll { $0 == panel }
        if groups[index].tabs.isEmpty { groups.remove(at: index) }
        else if groups[index].selected == panel { groups[index].selected = groups[index].tabs[0] }
        set(groups, leading: panel.isLeading)
        if wasLastShown, let replacement = groups.indices.contains(index) ? groups[index].selected : groups.last?.selected {
            if panel.isLeading { lastShownLeading = replacement } else { lastShownTrailing = replacement }
        }
    }

    func collapse(_ id: UUID, leading side: Bool) {
        var groups = side ? leading : trailing
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed.toggle()
        set(groups, leading: side)
    }

    func move(_ id: UUID, leading side: Bool, by offset: Int) {
        var groups = side ? leading : trailing
        guard let index = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(index + offset) else { return }
        groups.swapAt(index, index + offset)
        set(groups, leading: side)
    }

    func stack(_ panel: DockPanelID, on target: UUID) {
        var groups = panel.isLeading ? leading : trailing
        guard let source = groups.firstIndex(where: { $0.tabs.contains(panel) }),
              let destination = groups.firstIndex(where: { $0.id == target }), source != destination else { return }
        groups[source].tabs.removeAll { $0 == panel }
        if groups[source].tabs.isEmpty { groups.remove(at: source) }
        else if groups[source].selected == panel { groups[source].selected = groups[source].tabs[0] }
        guard let targetIndex = groups.firstIndex(where: { $0.id == target }) else { return }
        groups[targetIndex].tabs.append(panel)
        groups[targetIndex].selected = panel
        groups[targetIndex].collapsed = false
        set(groups, leading: panel.isLeading)
        lastShown = panel
        if panel.isLeading { lastShownLeading = panel } else { lastShownTrailing = panel }
    }

    func isVisible(_ panel: DockPanelID) -> Bool {
        (panel.isLeading ? leading : trailing).contains { $0.tabs.contains(panel) }
    }

    func selectedPanel(leading side: Bool) -> DockPanelID? {
        let panel = side ? lastShownLeading : lastShownTrailing
        let groups = side ? leading : trailing
        return groups.contains(where: { $0.tabs.contains(panel) }) ? panel : groups.first?.selected
    }

    private func set(_ groups: [PanelDockGroup], leading side: Bool) {
        if side { leading = groups } else { trailing = groups }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode([leading, trailing]) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
