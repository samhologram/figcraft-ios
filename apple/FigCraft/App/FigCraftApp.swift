import SwiftUI
import UIKit

@main
struct FigCraftApp: App {
    init() {
        // Installed fonts reach the engine once, in the background (the engine scans none on iOS).
        FontLoader.loadOnce()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { FigCraftDocument() }) { file in
            DocumentScene(document: file.document)
        }
        .commands {
            FigCraftCommands()
        }

        DocumentGroupLaunchScene("FigCraft") {
            NewFromPhotoButton()
            NewDocumentButton("New Design")
                .accessibilityIdentifier("newDocument")
        } background: {
            LaunchBackground()
        } overlayAccessoryView: { geometry in
            LaunchIcon(titleFrame: geometry.titleViewFrame)
        }
    }
}

/// One document window: the root view plus the hook that mirrors the engine history on this scene's UndoManager.
private struct DocumentScene: View {
    let document: FigCraftDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        EditorRootView(model: document.model)
            .onAppear { document.model.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in document.model.undoManager = manager }
    }
}

// MARK: - Launch scene

/// Plain system background: light or dark with the OS appearance.
struct LaunchBackground: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The app icon above the launch scene title (the UI layer provides the `LaunchIcon` image; nothing is shown
/// when it is missing).
struct LaunchIcon: View {
    let titleFrame: CGRect
    private let side: CGFloat = 64

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if UIImage(named: "LaunchIcon") != nil {
                    Image("LaunchIcon")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .offset(x: titleFrame.minX + 22, y: titleFrame.minY + 14)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
