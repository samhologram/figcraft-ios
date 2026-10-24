import CryptoKit
import Foundation

/// Public iCloud Documents folder when entitled, otherwise FigCraft's Files-visible local Documents folder.
enum FigCloudContainer {
    static let identifier = "iCloud.ca.hologram.figcraft"

    static func documentsFolder() throws -> URL {
        let fm = FileManager.default
        let root = fm.url(forUbiquityContainerIdentifier: identifier)
        let folder = root?.appending(path: "Documents", directoryHint: .isDirectory) ?? .documentsDirectory
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func existingFolders() -> [URL] {
        let local = URL.documentsDirectory
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else { return [local] }
        return [root.appending(path: "Documents", directoryHint: .isDirectory), local]
    }

    static func prepare() {
        Task.detached(priority: .utility) { _ = try? documentsFolder() }
    }
}

/// ReadConfiguration has source bytes and name, but no stable source URL. The digest identifies a repeated import.
enum FigNativeCopyMap {
    private static let key = "figcraft.nativeCopies.v1"
    private static let lock = NSLock()

    static func sourceKey(name: String, data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "file|\(name)|\(data.count)|\(digest)"
    }

    static func photoSourceKey(data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "photo-source|\(data.count)|\(digest)"
    }

    /// DocumentGroup reads its prepared native bytes under a browser-selected filename.
    static func preparedKey(data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "photo-native|\(data.count)|\(digest)"
    }

    private static func load() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: String].self, from: raw) else { return [:] }
        return map
    }

    static func existingCopy(for source: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let stored = load()[source] else { return nil }
        let file: String
        let folders: [URL]
        if stored.hasPrefix("local:") {
            file = String(stored.dropFirst("local:".count))
            folders = [.documentsDirectory]
        } else if stored.hasPrefix("cloud:") {
            file = String(stored.dropFirst("cloud:".count))
            folders = FigCloudContainer.existingFolders().filter { $0 != URL.documentsDirectory }
        } else {
            file = stored
            folders = FigCloudContainer.existingFolders()
        }
        return folders.map { $0.appending(path: file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func remember(_ url: URL, for source: String) {
        guard !source.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var map = load()
        let location = url.deletingLastPathComponent().standardizedFileURL == URL.documentsDirectory.standardizedFileURL
            ? "local:" : "cloud:"
        map[source] = location + url.lastPathComponent
        if let raw = try? JSONEncoder().encode(map) { UserDefaults.standard.set(raw, forKey: key) }
    }
}
