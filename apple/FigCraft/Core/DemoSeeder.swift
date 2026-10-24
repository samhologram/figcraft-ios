import Foundation
@preconcurrency import FigCraftKit

/// Demo content for screenshots and UI tests (`-FigCraftDemo`). New documents become the engine's "Mobile app"
/// template plus a prototype flow and click-through interactions, all added through engine commands.
enum DemoSeeder {
    enum SeedError: LocalizedError {
        case incomplete(String)

        var errorDescription: String? {
            switch self {
            case .incomplete(let reason): "FigCraft demo could not be prepared: \(reason)"
            }
        }
    }
    nonisolated static let launchArgument = "-FigCraftDemo"
    nonisolated static let autoCreateArgument = "-FigCraftDemoAutoCreate"
    nonisolated static let templateID = "mobile-app"

    nonisolated static var isEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(launchArgument) || args.contains(autoCreateArgument)
    }

    /// Builds and validates demo content. The caller reports failure instead of marking a blank fallback ready.
    nonisolated static func makeHandle(dark: Bool) throws -> DocumentHandle {
        let handle = try DocumentHandle.fromTemplate(templateId: templateID, dark: dark)
        let failures = seed(handle)
        if !failures.isEmpty { throw SeedError.incomplete(failures.joined(separator: "; ")) }
        guard isReady(handle) else { throw SeedError.incomplete("required frames or prototype content are missing") }
        return handle
    }

    /// Readback from DocumentGroup may be named Untitled; verify the saved fixture itself.
    nonisolated static func isReady(_ handle: DocumentHandle) -> Bool {
        let rows = handle.layers()
        let frames = rows.filter { $0.parent == nil && $0.kind == "frame" }
        guard frames.count >= 2,
              frames.contains(where: { $0.name == "Welcome" }),
              frames.contains(where: { $0.name == "Explore" }),
              rows.contains(where: { row in
                  guard let json = try? handle.nodeJson(id: row.id),
                        let object = JSONBridge.decodeObject(json),
                        let interactions = object["interactions"] as? [Any] else { return false }
                  return !interactions.isEmpty
              }),
              let presenter = try? handle.presenter(start: frames[0].id) else { return false }
        return !presenter.state().flows.isEmpty
    }

    /// Adds the flow, the click-navigate interaction between the first two top-level frames, a back action on
    /// the second, selects the first frame and fits the view. Failed steps are logged, never fatal.
    @discardableResult
    nonisolated static func seed(_ handle: DocumentHandle) -> [String] {
        var failures: [String] = []
        func step(_ id: String, _ params: [String: Any]) {
            do { _ = try handle.execute(id: id, paramsJson: JSONBridge.encode(params)) } catch {
                failures.append("\(id): \(error.localizedDescription)")
            }
        }
        let rows = handle.layers()
        let frames = rows.filter { $0.parent == nil && $0.kind == "frame" }
        if let first = frames.first {
            step("proto.flow.add", ["start": first.id, "name": "Flow 1"])
            if frames.count >= 2 {
                let second = frames[1]
                step("proto.interaction.add", ["id": buttonLike(in: first.id, rows: rows) ?? first.id, "dest": second.id])
                step("proto.interaction.add", ["id": second.id, "action": ["type": "back"]])
            }
            step("select.set", ["ids": [first.id]])
        }
        step("view.zoomFit", [:])
        if !failures.isEmpty { NSLog("FigCraftDemo: failed steps %@", failures.joined(separator: "; ")) }
        return failures
    }

    /// A button-like descendant of `frame` (name contains button/btn/cta), preferring shapes and frames.
    nonisolated private static func buttonLike(in frame: UInt64, rows: [LayerRow]) -> UInt64? {
        var inside = Set<UInt64>([frame])
        var candidates: [LayerRow] = []
        for row in rows {
            guard let parent = row.parent, inside.contains(parent) else { continue }
            inside.insert(row.id)
            let name = row.name.lowercased()
            if name.contains("button") || name.contains("btn") || name.contains("cta") { candidates.append(row) }
        }
        let preferred = candidates.first { ["frame", "rectangle", "component", "instance", "group"].contains($0.kind) }
        return (preferred ?? candidates.first)?.id
    }
}
