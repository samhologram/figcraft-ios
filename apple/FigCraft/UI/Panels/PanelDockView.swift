import SwiftUI

/// Persistent panel dock shared by both iPad columns. Tabs and group headers stay visible while content scrolls.
struct PanelDockView: View {
    @Bindable var model: EditorModel
    let leading: Bool

    private var groups: [PanelDockGroup] { leading ? model.panelDock.leading : model.panelDock.trailing }
    private var available: [DockPanelID] { DockPanelID.allCases.filter { $0.isLeading == leading } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(leading ? "Panels" : "Inspector").font(.headline)
                Spacer()
                Menu {
                    ForEach(available) { panel in
                        Button {
                            model.showPanel(panel)
                        } label: {
                            Label(panel.title, systemImage: model.panelDock.isVisible(panel) ? "checkmark" : "plus")
                        }
                        .accessibilityIdentifier("panels.show.\(panel.rawValue)")
                    }
                    Divider()
                    Button("Reset Panels") { model.panelDock.reset() }
                        .accessibilityIdentifier("panels.reset")
                } label: {
                    Label("Panels", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .accessibilityIdentifier(leading ? "panels.menu.leading" : "panels.menu.trailing")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            dockGroup(group, index: index)
                                .id(group.id)
                        }
                    }
                    .padding(8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .task {
                    await Task.yield()
                    guard let panel = model.panelDock.selectedPanel(leading: leading),
                          let group = groups.first(where: { $0.tabs.contains(panel) }) else { return }
                    reader.scrollTo(group.id, anchor: .top)
                }
                .onChange(of: model.panelDock.lastShown) { _, panel in
                    guard let panel, panel.isLeading == leading,
                          let group = groups.first(where: { $0.tabs.contains(panel) }) else { return }
                    withAnimation(.smooth) { reader.scrollTo(group.id, anchor: .top) }
                }
                .onChange(of: model.panelRequest) { _, _ in
                    let panel = model.lastRequestedPanel
                    guard panel.isLeading == leading,
                          let group = groups.first(where: { $0.tabs.contains(panel) }) else { return }
                    withAnimation(.smooth) { reader.scrollTo(group.id, anchor: .top) }
                }
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(leading ? "sidebar" : "inspector")
    }

    private func dockGroup(_ group: PanelDockGroup, index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(group.tabs) { panel in
                                Button { model.showPanel(panel) } label: {
                                    Text(panel.title)
                                        .font(.subheadline.weight(group.selected == panel ? .semibold : .regular))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 10)
                                        .frame(height: 36)
                                        .background(group.selected == panel ? Color.accentColor.opacity(0.18) : .clear,
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("panel.\(panel.rawValue)")
                                .accessibilityAddTraits(group.selected == panel ? .isSelected : [])
                                .id(panel)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: group.selected, initial: true) { _, selected in
                        withAnimation(.smooth) { reader.scrollTo(selected, anchor: .center) }
                    }
                    .onChange(of: model.panelRequest) { _, _ in
                        guard group.tabs.contains(model.lastRequestedPanel) else { return }
                        withAnimation(.smooth) { reader.scrollTo(model.lastRequestedPanel, anchor: .center) }
                    }
                }
                Button { model.panelDock.collapse(group.id, leading: leading) } label: {
                    Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                        .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.collapsed ? "Expand" : "Collapse")
                .accessibilityIdentifier("panelHeader.\(group.selected.rawValue).collapse")
                Menu {
                    Button("Move Up", systemImage: "arrow.up") { model.panelDock.move(group.id, leading: leading, by: -1) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "arrow.down") { model.panelDock.move(group.id, leading: leading, by: 1) }
                        .disabled(index == groups.count - 1)
                    Menu("Stack Here") {
                        ForEach(available.filter { $0 != group.selected && model.panelDock.isVisible($0) }) { panel in
                            Button(panel.title) { model.panelDock.stack(panel, on: group.id) }
                        }
                    }
                    Divider()
                    ForEach(group.tabs) { panel in
                        Button("Hide \(panel.title)", systemImage: "xmark") { model.panelDock.hide(panel) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 36)
                }
                .accessibilityIdentifier("panelHeader.\(group.selected.rawValue).menu")
            }
            .padding(.horizontal, 4)
            .background(.bar)
            // Keep the row itself unnamed: assigning it an identifier can mask the tab,
            // collapse and options button identifiers in the accessibility tree.
            .accessibilityElement(children: .contain)
            if !group.collapsed {
                Divider()
                panelContent(group.selected)
                    .frame(minHeight: 230, maxHeight: 480)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func panelContent(_ panel: DockPanelID) -> some View {
        switch panel {
        case .layers: LayersPanel(model: model)
        case .assets: AssetsPanel(model: model)
        case .design: DesignInspector(model: model)
        case .prototype: PrototypeInspector(model: model)
        case .inspect: InspectInspector(model: model)
        }
    }
}
