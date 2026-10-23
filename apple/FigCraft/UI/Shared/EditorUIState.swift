import SwiftUI

/// Which iPhone panel sheet is open.
enum PhoneSheet: String, Identifiable {
    case layers, design, prototype
    var id: String { rawValue }
}

/// View-only state shared between the root view and the layouts (never document state).
@MainActor @Observable
final class EditorUIState {
    /// iPhone: the panel sheet that is up (root presentations wait for it to close).
    var phoneSheet: PhoneSheet?
    /// iPad (narrow window): the sidebar and inspector are overlays; only one shows at a time.
    var padOverlayWide = true
    /// Requests to open the comments / version history sheets (the root view presents them).
    var showComments = false
    var showVersions = false
    /// Prototype settings last sent per page (the engine does not report them).
    var protoMirrors: [UInt64: ProtoSettingsMirror] = [:]
}
