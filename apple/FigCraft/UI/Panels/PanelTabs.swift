import SwiftUI

/// The tab row at the top of a panel column or sheet (`panel.<rawValue>` buttons). Labels never wrap.
struct PanelTabs<Tab: Hashable & CaseIterable & RawRepresentable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(Tab.allCases), id: \.rawValue) { tab in
                        let active = selection == tab
                        Button {
                            selection = tab
                        } label: {
                            Text(verbatim: tab.rawValue.prefix(1).uppercased() + tab.rawValue.dropFirst())
                                .font(.subheadline.weight(active ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background {
                                    if active { Capsule().fill(Color.accentColor.opacity(0.18)) }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("panel.\(tab.rawValue)")
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .id(tab.rawValue)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection, initial: true) { _, selected in
                withAnimation(.smooth) { reader.scrollTo(selected.rawValue, anchor: .center) }
            }
        }
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// A titled inspector section: header with optional trailing buttons, content below, `section.<name>` identifier.
struct InspectorSection<Content: View, Trailing: View>: View {
    let name: String
    let title: String
    let trailing: Trailing
    let content: Content

    init(_ name: String, title: String,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.name = name
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.\(name)")
    }
}

extension InspectorSection where Trailing == EmptyView {
    init(_ name: String, title: String, @ViewBuilder content: () -> Content) {
        self.init(name, title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A small icon button for section headers and rows.
struct IconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
