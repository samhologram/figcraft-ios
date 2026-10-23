import Foundation

/// iPad sidebar (iPhone sheet) panels. Raw values are the `panel.<rawValue>` accessibility identifiers.
enum LeftPanel: String, CaseIterable, Sendable {
    case layers, assets
}

/// Inspector tabs. Raw values are the `panel.<rawValue>` accessibility identifiers.
enum RightPanel: String, CaseIterable, Sendable {
    case design, prototype, inspect
}
