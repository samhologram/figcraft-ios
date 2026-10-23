import Foundation
import CoreText
import UIKit
@preconcurrency import FigCraftKit

extension Notification.Name {
    /// Posted on the main queue once the system fonts reached the engine (canvases re-render).
    static let figcraftFontsLoaded = Notification.Name("ca.hologram.figcraft.fontsLoaded")
}

/// The engine scans no system font directory on iOS, so the app feeds it the installed fonts once at launch:
/// `UIFont` families -> CoreText font -> its file URL -> bytes -> `loadFont(data:)`.
enum FontLoader {
    private static let started = Locked(false)
    /// Fonts above this size are skipped (the engine keeps every face in memory).
    private static let maxFileBytes = 48 * 1024 * 1024

    /// Starts the one-time background load. Safe to call repeatedly.
    static func loadOnce() {
        let first = started.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        Task.detached(priority: .utility) {
            let count = loadAll()
            await MainActor.run {
                NSLog("FigCraft: loaded %d system font files", count)
                NotificationCenter.default.post(name: .figcraftFontsLoaded, object: nil)
            }
        }
    }

    /// Enumerates and loads every readable system font file. Returns how many files the engine received.
    nonisolated static func loadAll() -> Int {
        var seen = Set<URL>()
        var loaded = 0
        for family in UIFont.familyNames {
            for name in UIFont.fontNames(forFamilyName: family) {
                let font = CTFontCreateWithName(name as CFString, 12, nil)
                guard let attribute = CTFontCopyAttribute(font, kCTFontURLAttribute),
                      let nsURL = attribute as? NSURL else { continue }
                let url = nsURL as URL
                guard seen.insert(url).inserted else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= maxFileBytes,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                _ = loadFont(data: data)
                loaded += 1
            }
        }
        return loaded
    }
}

/// Minimal lock box so static state is concurrency-safe without extra dependencies.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
