import SwiftUI
import UIKit
@preconcurrency import FigCraftKit

/// One open document: the engine handle plus everything the UI observes. Every engine call goes through here,
/// so state, undo registration and UI requests stay in step.
@MainActor @Observable
final class EditorModel {
    let handle: DocumentHandle
    var state: DocState
    var pages: [PageInfo] = []
    var layers: [LayerRow] = []
    /// `node.get` of the single selected node (nil for none or many): the inspector source.
    var selectionJSON: [String: Any]?
    var overlay: Overlay
    var tool: String
    var leftPanel: LeftPanel = .layers
    var rightPanel: RightPanel = .design
    let panelDock = PanelDockLayout()
    var panelRequest = 0
    var lastRequestedPanel: DockPanelID = .layers
    var inspectorVisible = true
    var sidebarVisible = true

    func showPanel(_ panel: DockPanelID) {
        panelDock.show(panel)
        lastRequestedPanel = panel
        panelRequest += 1
        if panel.isLeading { sidebarVisible = true } else { inspectorVisible = true }
        switch panel {
        case .layers: leftPanel = .layers
        case .assets: leftPanel = .assets
        case .design: rightPanel = .design
        case .prototype: rightPanel = .prototype
        case .inspect: rightPanel = .inspect
        }
    }
    var lastError: String?
    var toast: String?
    var isDemoReady = false
    /// Bumps whenever the canvas must re-render.
    var canvasRevision = 0
    /// Set when the engine asks the UI to rename a layer (`layers.rename`).
    var renameLayerID: UInt64?

    var pendingCommand: String?
    var showCommandPalette = false
    var showImporter = false
    var showExport = false
    var showTemplates = false
    var showVersions = false
    var isPresenting = false {
        didSet {
            if isPresenting { presenter?.startTicking() } else { presenter?.stop() }
        }
    }
    var presenter: PresentModel?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored var lastHistoryId: UInt64
    @ObservationIgnored var lastRevision: UInt64
    @ObservationIgnored var suppressUndoRegistration = false
    @ObservationIgnored private var heavyStale = true
    @ObservationIgnored private var lastHeavy = Date.distantPast
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var fontObserver: NSObjectProtocol?

    init(handle: DocumentHandle, demoReady: Bool = false) {
        self.handle = handle
        let initial = handle.state()
        state = initial
        tool = initial.tool
        overlay = handle.overlay()
        lastHistoryId = initial.historyId
        lastRevision = initial.revision
        isDemoReady = demoReady
        reloadHeavy()
        fontObserver = NotificationCenter.default.addObserver(forName: .figcraftFontsLoaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvasRevision += 1 }
        }
    }

    // MARK: Commands

    /// Executes a command, refreshes, mirrors the history on the UndoManager and handles UI requests.
    /// Errors go to `lastError` with the full message. Returns the decoded result JSON.
    @discardableResult
    func run(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        if id == "edit.undo" { undo(); return nil }
        if id == "edit.redo" { redo(); return nil }
        let result: Any?
        do {
            let text = try handle.execute(id: id, paramsJson: JSONBridge.encode(params))
            result = JSONBridge.decode(text)
        } catch {
            report(error)
            result = nil
        }
        refresh()
        handleUIRequests()
        return result
    }

    /// True when the command can run now (observation tracks the document revision).
    func isEnabled(_ id: String) -> Bool {
        _ = state.revision
        _ = state.selection
        return handle.disabledReason(id: id) == nil
    }

    /// Menus and the palette: runs at once when the command needs nothing, else asks for parameters first.
    func present(_ id: String) {
        if CommandCatalog.shared.needsParams(id) {
            pendingCommand = id
        } else {
            run(id)
        }
    }

    func setTool(_ id: String) { run("tool.\(id)") }

    func select(_ ids: [UInt64]) { run("select.set", ["ids": ids]) }

    /// `node.set` on the selection: one undo step.
    func setProps(_ props: [String: Any]) {
        guard !state.selection.isEmpty else { return }
        run("node.set", ["ids": state.selection, "props": props])
    }

    /// A slider or scrub drag is one undo step.
    func beginDrag(_ label: String) {
        do { try handle.beginInteraction(label: label) } catch { report(error) }
    }

    func endDrag() {
        do { try handle.endInteraction() } catch { report(error) }
        refresh()
    }

    // MARK: State

    /// Re-reads the engine state. `full: false` (pointer moves) throttles the heavy lists.
    func refresh(full: Bool = true) {
        let new = handle.state()
        if new.revision != lastRevision {
            lastRevision = new.revision
            canvasRevision += 1
            heavyStale = true
        }
        state = new
        if tool != new.tool { tool = new.tool }
        overlay = handle.overlay()
        if let message = new.message, !message.isEmpty { showToast(message) }
        if heavyStale, full || Date().timeIntervalSince(lastHeavy) > 0.12 { reloadHeavy() }
        if new.historyId != lastHistoryId {
            lastHistoryId = new.historyId
            if !suppressUndoRegistration { registerUndoStep(label: new.undoLabel) }
        }
    }

    func reloadHeavy() {
        heavyStale = false
        lastHeavy = Date()
        pages = handle.pages()
        layers = handle.layers()
        if state.selection.count == 1, let id = state.selection.first,
           let json = try? handle.nodeJson(id: id) {
            selectionJSON = JSONBridge.decodeObject(json)
        } else {
            selectionJSON = nil
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func report(_ error: Error) {
        lastError = Self.message(of: error)
    }

    /// The full message of a bridge error (the generated enum carries it as an associated value).
    nonisolated static func message(of error: Error) -> String {
        func find(_ value: Any, depth: Int) -> String? {
            guard depth < 4 else { return nil }
            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                if child.label == "message", let text = child.value as? String { return text }
                if let text = find(child.value, depth: depth + 1) { return text }
            }
            return nil
        }
        return find(error, depth: 0) ?? error.localizedDescription
    }

    // MARK: UI requests

    func handleUIRequests() {
        for request in handle.takeUiRequests() {
            let data = JSONBridge.decodeObject(request.dataJson) ?? [:]
            switch request.kind {
            case "present", "preview":
                startPresenting(from: (data["start"] as? NSNumber)?.uint64Value)
            case "home.templates":
                showTemplates = true
            case "dialog.saveAs":
                showExport = true
            case "panel.versionHistory":
                showVersions = true
            case "present.options":
                break
            case "layers.rename":
                renameLayerID = (data["id"] as? NSNumber)?.uint64Value ?? state.selection.first
            default:
                showToast(request.kind)
            }
        }
    }

    // MARK: Presenting

    func startPresenting(from frame: UInt64?) {
        do {
            let player = try handle.presenter(start: frame)
            presenter?.stop()
            presenter = PresentModel(presenter: player)
            isPresenting = true
        } catch {
            report(error)
        }
    }

    // MARK: Import and export

    /// `file.import` for each picked file (SVG, images, .figcraft, .fig pages): bytes go in as base64.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 256 * 1024 * 1024 else {
                    lastError = "\(url.lastPathComponent) is too large to import."
                    continue
                }
                run("file.import", ["data": data.base64EncodedString(), "name": url.lastPathComponent])
            } catch {
                lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Selection (or the page when nothing is selected) as PNG at 2x.
    func exportPNG() -> Data? { export { try handle.exportPng(ids: [], scale: 2) } }
    func exportSVG() -> Data? { export { try handle.exportSvg(ids: []) } }
    func exportPDF() -> Data? { export { try handle.exportPdf() } }

    private func export(_ body: () throws -> Data) -> Data? {
        do { return try body() } catch {
            report(error)
            return nil
        }
    }
}
