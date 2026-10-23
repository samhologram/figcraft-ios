import SwiftUI
@preconcurrency import FigCraftKit

/// Full-screen prototype player over black. Taps go to the prototype, frame changes animate with the interaction's
/// transition, a swipe from the leading edge (or Back) goes back.
struct PresentView: View {
    let model: PresentModel
    let close: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var frameKey = 0
    @State private var shownFrame: UInt64?
    @State private var viewSize = CGSize.zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    if let image = model.image {
                        Image(decorative: image, scale: displayScale)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(frameKey)
                            .transition(Self.transition(model.state))
                    }
                    hotspots(in: geo.size)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in model.tap(at: value.location, in: geo.size) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { drag in
                            if drag.startLocation.x < 28, drag.translation.width > 70, abs(drag.translation.height) < 120 { model.back() }
                        }
                )
                .onAppear { sizeChanged(geo.size) }
                .onChange(of: geo.size) { _, new in sizeChanged(new) }
            }
            .ignoresSafeArea()
            .accessibilityHidden(false)
            .accessibilityLabel("Prototype: \(model.state.frameName)")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityIdentifier("present.canvas")
            controls
        }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("present")
        .onChange(of: model.image.map { ObjectIdentifier($0) }) { _, _ in
            let frame = model.state.frame
            if shownFrame == nil {
                shownFrame = frame
                frameKey += 1
            } else if shownFrame != frame {
                shownFrame = frame
                let duration = Double(max(0, min(model.state.durationMs, 5000))) / 1000
                if model.state.transition == "instant" || duration == 0 {
                    frameKey += 1
                } else {
                    withAnimation(.easeInOut(duration: duration)) { frameKey += 1 }
                }
            }
        }
    }

    private func sizeChanged(_ size: CGSize) {
        viewSize = size
        model.render(size: size, scale: displayScale)
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    control("chevron.left", "Back", "present.back", enabled: model.state.canGoBack) { model.back() }
                    control("arrow.counterclockwise", "Restart", "present.restart") { model.restart() }
                    if model.state.flows.count > 1 {
                        Menu {
                            ForEach(model.state.flows, id: \.start) { flow in
                                Button(flow.name) { model.restart(from: flow.start) }
                                    .accessibilityIdentifier("present.flow.\(flow.start)")
                            }
                        } label: {
                            Image(systemName: "list.bullet").frame(width: 44, height: 40).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Flows")
                        .accessibilityIdentifier("present.flows")
                    }
                }
                .padding(.horizontal, 6)
                .glassEffect(.regular, in: Capsule())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 40).contentShape(Rectangle())
                }
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("present.close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func control(_ symbol: String, _ label: String, _ id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 40).contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Hotspots and transitions

    @ViewBuilder
    private func hotspots(in size: CGSize) -> some View {
        let w = model.state.width, h = model.state.height
        if !model.flashedHotspots.isEmpty, w > 0, h > 0 {
            let scale = min(size.width / w, size.height / h)
            let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2
            ForEach(Array(model.flashedHotspots.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: r.width * scale, height: r.height * scale)
                    .position(x: ox + (r.x + r.width / 2) * scale, y: oy + (r.y + r.height / 2) * scale)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("present.hotspots")
        }
    }

    /// Dissolve and smart animate fade; push, slide and move use the edge the direction names; instant has none.
    static func transition(_ state: PresentState) -> AnyTransition {
        let edge: Edge = switch state.direction {
        case "left": .leading
        case "right": .trailing
        case "top": .top
        default: .bottom
        }
        let opposite: Edge = switch edge {
        case .leading: .trailing
        case .trailing: .leading
        case .top: .bottom
        case .bottom: .top
        }
        switch state.transition {
        case "dissolve", "smartAnimate": return .opacity
        case "push": return .asymmetric(insertion: .move(edge: opposite), removal: .move(edge: edge))
        case "moveIn", "slideIn": return .asymmetric(insertion: .move(edge: edge), removal: .opacity)
        case "moveOut", "slideOut": return .asymmetric(insertion: .opacity, removal: .move(edge: edge))
        default: return .identity
        }
    }
}
