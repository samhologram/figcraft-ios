// Re-exports nothing by itself: the UniFFI-generated `figcraft_apple.swift` (produced by
// apple/scripts/build-xcframework.sh) is compiled into this module, so `import FigCraftKit`
// exposes DocumentHandle, Presenter, CommandInfo, DocState, etc.
// This file keeps the source directory present before the first bridge build.
@_exported import Foundation
