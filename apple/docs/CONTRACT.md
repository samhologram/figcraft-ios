# FigCraft for iOS and iPadOS: internal contracts

Single source of truth shared by the Rust bridge, the Swift core and the Swift UI. Change it first, then the code on
both sides. Recipe: `/Users/samuelhalle/Code/CraftApps/COOKBOOK.md`. Working reference port (read-only):
`/Users/samuelhalle/Code/LC/lightcraft-ios/apple`.

## 1. Directory ownership

| Path | Owner | What |
|---|---|---|
| `apple/bridge/` | Rust bridge | `figcraft-apple` crate (own `[workspace]`, UniFFI 0.32 proc-macros, staticlib) |
| `apple/scripts/` | Rust bridge | build-xcframework, check-command-ids, tool-coverage, feature-coverage |
| `apple/FigCraftKit/` | Rust bridge | local Swift package: generated `FigCraftBridge.xcframework` + generated `figcraft_apple.swift` + `Exports.swift` |
| `apple/docs/tool-map.toml`, `apple/docs/FEATURE_COVERAGE.md` | Rust bridge | coverage maps (generated / checked by scripts) |
| `apple/project.yml` | Swift core | XcodeGen spec (`.xcodeproj` generated, gitignored) |
| `apple/FigCraft/App/` | Swift core | `@main`, `DocumentGroup` scene, `DocumentGroupLaunchScene`, menu bar `Commands` |
| `apple/FigCraft/Core/` | Swift core | `FigCraftDocument`, `EditorModel`, `CommandCatalog`, `PresentModel`, demo seeding, fonts, focused values |
| `apple/FigCraft/Canvas/` | Swift core | `CanvasView` (render + gestures → engine pointer events), selection overlay |
| `apple/FigCraft/UI/` | Swift UI | `Shared/`, `Pad/`, `Phone/`, `Panels/`, `Present/`, `Commands/` (palette, `CommandSheet`) |
| `apple/FigCraft/Resources/` | Swift UI | `Assets.xcassets` (AppIcon, AccentColor) |
| `apple/FigCraftTests/` | Swift core | swift-testing bridge smoke tests |
| `apple/FigCraftUITests/` | Swift UI | XCUITest UI tests + coverage tours |
| `FORK.md`, `.github/workflows/apple-ios.yml`, `apple/README.md`, `apple/docs/CONTRACT.md` | Orchestrator | |

Upstream files (everything outside `apple/`, `FORK.md`, `.github/workflows/apple-*.yml`) are never edited.

## 2. Data model: document app

A FigCraft file is one `.figcraft` file (zip-like bytes from `figcraft_format::save_bytes`). iOS app = `DocumentGroup`.

- UTType exported: `ca.hologram.figcraft.document`, extension `figcraft`, conforms to `public.data`, `public.content`.
- UTTypes imported (open/import): `com.figma.fig` (`fig`, via `file.open` data), `public.svg-image`, `public.png`,
  `public.jpeg` (imports go through `file.import` with base64 `data`).
- `FigCraftDocument: ReferenceFileDocument` (Snapshot = `Data`):
  - `init()` (New): `DocumentHandle.newDocument(name: "Untitled", dark: <system scheme>)`. With launch arg
    `-FigCraftDemo` the *new* document is built by `DemoSeeder` instead (see §6).
  - `init(configuration:)`: `DocumentHandle.open(data:, name:)` with the file's bytes.
  - `snapshot(contentType:)`: `handle.saveBytes()` (engine bytes with thumbnail, no disk access).
  - `fileWrapper(snapshot:configuration:)`: `FileWrapper(regularFileWithContents:)`.
  - Engine history is mirrored on the scene `UndoManager`: after every call whose `historyId` changed (and that was
    not itself an undo/redo), register an undo action that calls `model.undo()` (redo symmetric).
- One engine `Session` per document (each `DocumentHandle` owns one). Paths are never used for the document; the
  bridge only uses bytes APIs (`load_bytes`, `file_bytes`).

## 3. Rust bridge API (crate `figcraft_apple`, Swift module `FigCraftKit`)

Swift names are what UniFFI 0.32 generates (snake_case → camelCase, `Vec<u8>` → `Data`, `u64` → `UInt64`, `u32` →
`UInt32`, `f64` → `Double`, `Option<T>` → `T?`, `Vec<T>` → `[T]`). Every exported fn runs engine code under
`catch_unwind`; poisoned locks are recovered; never panics.

```rust
#[derive(uniffi::Error)] pub enum BridgeError { Failed { message: String } }   // Swift: BridgeError.Failed(message:)

#[derive(uniffi::Record)] pub struct CommandInfo {
    pub id: String, pub label: String,
    pub menu: Vec<String>,          // from engine catalog::MENU: ["Edit","Copy as"]; empty = not in menus
    pub shortcut: Option<String>,   // keymap::primary(id, Platform mac) e.g. "Cmd+Shift+R"
    pub params: String,             // CommandSpec.params doc
    pub undoable: bool,             // CommandSpec.history
}
#[derive(uniffi::Record)] pub struct MenuSection { pub title: String, pub items: Vec<MenuEntry> }
#[derive(uniffi::Record)] pub struct MenuEntry {
    pub kind: String,     // "command" | "separator" | "submenu"
    pub id: String,       // command id ("" for separator/submenu)
    pub label: String,    // catalog label (submenu: its title)
    pub children: Vec<MenuEntry>,   // only for "submenu" (one level deep is enough; deeper flattened)
}
#[derive(uniffi::Record)] pub struct ToolGroup { pub key: String, pub name: String, pub tools: Vec<ToolInfo> }
#[derive(uniffi::Record)] pub struct ToolInfo {
    pub id: String,       // ToolId::id(): "move","hand","scale","frame","section","slice","rectangle","line","arrow",
                          // "ellipse","polygon","star","pen","pencil","shapeBuilder","text","comment","eyedropper"
    pub command: String,  // "tool.<id>" (eyedropper → its catalog command)
    pub label: String,    // catalog label or humanized id
    pub shortcut: Option<String>,
}
#[derive(uniffi::Record)] pub struct ParamField {      // structured view of a params doc; best effort
    pub key: String,      // "" = free-form remainder
    pub kind: String,     // "number","integer","bool","choice","string","ids","id","color","json"
    pub min: Option<f64>, pub max: Option<f64>,
    pub default_json: Option<String>,
    pub choices: Vec<String>,
    pub label: String,    // humanized key
    pub is_optional: bool,
    pub doc: String,      // raw fragment
}
#[derive(uniffi::Record)] pub struct DocState {
    pub name: String,
    pub page: u64, pub page_count: u32,
    pub selection: Vec<u64>,
    pub tool: String,             // current ToolId::id()
    pub can_undo: bool, pub can_redo: bool,
    pub undo_label: Option<String>, pub redo_label: Option<String>,
    pub revision: u64,            // engine DocState.revision + bridge counter: changes on anything visible
    pub history_id: u64,          // changes when an undo step is recorded / undone / redone
    pub dirty: bool,
    pub zoom: f64, pub center_x: f64, pub center_y: f64,   // ViewState cx, cy, zoom
    pub editing_text: bool,       // a text node is in text-edit mode (show the keyboard)
    pub vector_editing: bool,
    pub message: Option<String>,  // Session.message (toast), taken (cleared) by state()
}
#[derive(uniffi::Record)] pub struct PageInfo { pub id: u64, pub name: String, pub is_divider: bool }
#[derive(uniffi::Record)] pub struct LayerRow {           // flattened layer tree of the current page, z-order top first
    pub id: u64, pub parent: Option<u64>, pub depth: u32,
    pub name: String,
    pub kind: String,             // NodeKind lower camel: "frame","group","section","rectangle","ellipse","polygon","star",
                                  // "line","vector","text","booleanOp","component","componentSet","instance","slice"
    pub visible: bool, pub locked: bool, pub has_children: bool,
    pub selected: bool,
}
#[derive(uniffi::Record)] pub struct Rect { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
#[derive(uniffi::Record)] pub struct Overlay {            // what the canvas draws over the render, in VIEW points
    pub selection: Vec<Rect>,     // per selected node, axis-aligned bounds
    pub bounds: Option<Rect>,     // union (resize handles go here)
    pub hover: Option<Rect>,
    pub marquee: Option<Rect>,
    pub caret: Option<Rect>,      // text caret while editing
    pub guides: Vec<Rect>,        // snapping guides/measurements as thin rects (best effort)
}
#[derive(uniffi::Record)] pub struct RenderedImage {
    pub width: u32, pub height: u32,
    pub rgba: Vec<u8>,            // RGBA8 PREMULTIPLIED (tiny-skia data as is), stride = width*4
}
#[derive(uniffi::Record)] pub struct UiRequest { pub kind: String, pub data_json: String }
#[derive(uniffi::Record)] pub struct TemplateInfo { pub id: String, pub name: String, pub description: String, pub kind: String, pub size: String }

#[derive(uniffi::Object)] pub struct DocumentHandle { /* Mutex<Inner{session, revision, history_id}> */ }
#[uniffi::export] impl DocumentHandle {
    #[uniffi::constructor] pub fn new_document(name: String, dark: bool) -> Arc<Self>;  // Session::empty + set_ui_dark + file.new
    #[uniffi::constructor] pub fn open(data: Vec<u8>, name: String) -> Result<Arc<Self>, BridgeError>; // .figcraft or .fig bytes
    #[uniffi::constructor] pub fn from_template(template_id: String, dark: bool) -> Result<Arc<Self>, BridgeError>;
    pub fn save_bytes(&self) -> Result<Vec<u8>, BridgeError>;      // file_bytes(ds) incl. thumbnail; marks saved
    pub fn execute(&self, id: String, params_json: String) -> Result<String, BridgeError>; // result JSON
    pub fn disabled_reason(&self, id: String) -> Option<String>;   // None = can run. Best effort: unknown id, no doc,
        // empty-selection commands ("{ids?}" docs with no selection), read-only doc, iOS-excluded; never runs the command
    pub fn undo(&self) -> Result<bool, BridgeError>;
    pub fn redo(&self) -> Result<bool, BridgeError>;
    pub fn state(&self) -> DocState;
    pub fn pages(&self) -> Vec<PageInfo>;
    pub fn layers(&self) -> Vec<LayerRow>;                          // current page
    pub fn node_json(&self, id: u64) -> Result<String, BridgeError>; // = execute("node.get",{id})
    pub fn take_ui_requests(&self) -> Vec<UiRequest>;               // drains Session.ui_requests
    // Canvas. View points = SwiftUI points of the canvas view; the engine ViewState holds vw/vh in points.
    pub fn set_viewport(&self, width: f64, height: f64);            // ViewState vw/vh; first call on a fresh doc zooms to fit
    pub fn set_view(&self, center_x: f64, center_y: f64, zoom: f64); // clamped to engine MIN/MAX zoom
    pub fn pan(&self, dx: f64, dy: f64);                            // view points
    pub fn zoom_at(&self, zoom: f64, x: f64, y: f64);               // anchor in view points
    pub fn render(&self, width_px: u32, height_px: u32, scale: f64) -> Result<RenderedImage, BridgeError>;
        // whole viewport at `scale` px per view point (Retina). Snapshot doc/page/view under the lock, render OUTSIDE it
        // (render_view_single; safe from a background thread). Background = page colour.
    pub fn overlay(&self) -> Overlay;
    pub fn pointer(&self, kind: String, x: f64, y: f64, shift: bool, alt: bool, cmd: bool, ctrl: bool, pressure: Option<f64>) -> Result<(), BridgeError>;
        // kind: "down","move","up","hover","double". x,y in view points → page coords via ViewState.screen_to_page;
        // a down…up drag is ONE undo step (engine handles it)
    pub fn key(&self, name: String, shift: bool, alt: bool, cmd: bool) -> Result<bool, BridgeError>;
        // text editing: textedit::key ("Left","Right","Up","Down","Backspace","Delete","Enter","Escape","Tab","Home","End");
        // otherwise Session::tool_key. true = handled
    pub fn insert_text(&self, text: String) -> Result<(), BridgeError>;   // textedit::insert while editing
    pub fn thumbnail(&self, edge: u32) -> Result<RenderedImage, BridgeError>;   // first page fit into edge×edge
    pub fn export_png(&self, ids: Vec<u64>, scale: f64) -> Result<Vec<u8>, BridgeError>;  // empty ids = selection, else page
    pub fn export_svg(&self, ids: Vec<u64>) -> Result<Vec<u8>, BridgeError>;
    pub fn export_pdf(&self) -> Result<Vec<u8>, BridgeError>;      // frames PDF
    pub fn begin_interaction(&self, label: String) -> Result<(), BridgeError>; // slider drag = 1 undo step
    pub fn end_interaction(&self) -> Result<(), BridgeError>;      // commit
    pub fn presenter(&self, start: Option<u64>) -> Result<Arc<Presenter>, BridgeError>;
}

// Prototype playback (port of the desktop crates/ui-egui/src/present.rs player logic WITHOUT egui, in the bridge).
#[derive(uniffi::Record)] pub struct PresentState {
    pub frame: u64, pub frame_name: String,
    pub width: f64, pub height: f64,          // device/viewport size in prototype points (frame size or device screen)
    pub can_go_back: bool,
    pub overlay_count: u32,
    pub flows: Vec<FlowInfo>,                 // the page's flow starting points
    pub transition: String,                   // last navigation: "instant","dissolve","smartAnimate","moveIn","moveOut","push","slideIn","slideOut"
    pub direction: String,                    // "left","right","top","bottom" or ""
    pub duration_ms: u32,
    pub open_url: Option<String>,             // set once after an openUrl action (Swift opens it), cleared by state()
    pub generation: u64,                      // bumps whenever the picture changes
}
#[derive(uniffi::Record)] pub struct FlowInfo { pub start: u64, pub name: String }
#[derive(uniffi::Object)] pub struct Presenter { /* Arc<Mutex<..>> to the handle's session + own player state */ }
#[uniffi::export] impl Presenter {
    pub fn state(&self) -> PresentState;
    pub fn render(&self, width_px: u32, height_px: u32) -> Result<RenderedImage, BridgeError>; // current frame + overlays + scroll, fit to the size
    pub fn tap(&self, x: f64, y: f64) -> bool;               // x,y in prototype points (0…width, 0…height); true = something reacted
    pub fn press(&self, x: f64, y: f64, down: bool) -> bool; // onPress / mouseDown / mouseUp
    pub fn drag(&self, dx: f64, dy: f64) -> bool;            // scrolls scrollable frames / onDrag
    pub fn key(&self, key: String) -> bool;                  // keyPress triggers
    pub fn tick(&self, now_ms: f64) -> bool;                 // afterDelay timers; true = picture changed
    pub fn back(&self) -> bool;
    pub fn restart(&self, start: Option<u64>);
    pub fn hotspots(&self) -> Vec<Rect>;                     // for hint flashes, prototype points
}

#[uniffi::export] pub fn command_catalog() -> Vec<CommandInfo>;
#[uniffi::export] pub fn menu_layout() -> Vec<MenuSection>;           // catalog::MENU in order (File…Help, Tools last)
#[uniffi::export] pub fn tool_groups() -> Vec<ToolGroup>;             // parsed from include_str!(crates/ui-egui/src/toolbar.rs) GROUPS; fallback ToolId::ALL
#[uniffi::export] pub fn command_params(id: String) -> Vec<ParamField>;
#[uniffi::export] pub fn command_platform_support(id: String) -> Option<String>; // Some(reason) if in ios-excluded-commands.txt
#[uniffi::export] pub fn templates() -> Vec<TemplateInfo>;
#[uniffi::export] pub fn load_font(data: Vec<u8>) -> Vec<String>;     // figcraft_text::fontdb::load_font_bytes; returns families
#[uniffi::export] pub fn font_families() -> Vec<String>;
#[uniffi::export] pub fn engine_version() -> String;
```

Bridge data files: `ui-commands.txt` (every command id the Swift sources reference literally; checked by
`scripts/check-command-ids.sh` against `command_catalog()`), `ios-excluded-commands.txt` (`id<TAB>reason`, e.g.
`window.new	one document per scene on iOS`, `plugin.import	…`, `collab.*`; be conservative), embedded with
`include_str!`.

Engine facts the bridge relies on: `Session::execute` (lib.rs:937), `undo/redo -> Result<bool>`, `begin_interaction`
/`commit_interaction`, `Session::pointer(&PointerEvent)` (tools.rs:944; PointerEvent page coords + `sx,sy` screen +
`zoom`), `Session::tool_key`, `textedit::{insert,key}`, `figcraft_render::render_view_single`, `cmd::file::{file_bytes,
thumbnail, export_bytes, frames_pdf}`, `figcraft_format::load_bytes`, `catalog::MENU`, `keymap::primary`,
`templates::find(id).build(bg)`, `proto_run::*` helpers. Fonts: `figcraft_text` scans no system directory on iOS
(its `system_font_dirs` has no iOS arm) — Swift feeds system fonts through `load_font` (upstream note).

## 4. Swift core surface (`apple/FigCraft/Core`, `apple/FigCraft/Canvas`)

```swift
@MainActor @Observable final class EditorModel {
    let handle: DocumentHandle
    var state: DocState                     // refreshed after every call
    var pages: [PageInfo]
    var layers: [LayerRow]
    var selectionJSON: [String: Any]?       // node.get of the single selected node (nil for 0 or many) — inspector source
    var overlay: Overlay
    var tool: String                        // == state.tool
    var leftPanel: LeftPanel                // .layers .assets  (iPad sidebar; iPhone sheet)
    var rightPanel: RightPanel              // .design .prototype .inspect
    var inspectorVisible: Bool              // iPad trailing inspector column
    var sidebarVisible: Bool
    var lastError: String?                  // alert with the full message
    var toast: String?                      // DocState.message
    var isDemoReady: Bool
    var canvasRevision: Int                 // bumps whenever the canvas must re-render
    weak var undoManager: UndoManager?

    func run(_ id: String, _ params: [String: Any] = [:]) -> Any?   // execute + refresh + undo registration + ui requests; errors → lastError
    func isEnabled(_ id: String) -> Bool    // disabledReason == nil
    func present(_ id: String)              // menus/palette: runs directly when the command needs no required params, else pendingCommand = id
    func setTool(_ id: String)              // run("tool.<id>")
    func select(_ ids: [UInt64])            // run("select.set", ["ids": ids])
    func setProps(_ props: [String: Any])   // run("node.set", ["ids": selection, "props": props]) (one undo step)
    func beginDrag(_ label: String); func endDrag()   // slider/scrub = one undo step
    func undo(); func redo()
    func refresh()
    func importFiles(_ urls: [URL])         // file.import with base64 data + name
    func exportPNG() -> Data?; func exportSVG() -> Data?; func exportPDF() -> Data?
    func startPresenting(from frame: UInt64?)   // presenter = PresentModel(...); isPresenting = true
    var pendingCommand: String?             // CommandSheet shows it (params form from commandParams)
    var showCommandPalette: Bool
    var showImporter: Bool
    var showExport: Bool
    var showTemplates: Bool
    var isPresenting: Bool
    var presenter: PresentModel?
}
enum LeftPanel: String, CaseIterable { case layers, assets }        // panel.<rawValue>
enum RightPanel: String, CaseIterable { case design, prototype, inspect }

@MainActor @Observable final class PresentModel {   // wraps Presenter; drives tick with a TimelineView/Timer
    var state: PresentState
    var image: CGImage?
    func tap(at: CGPoint, in size: CGSize); func back(); func restart(); func tick(); func render(size: CGSize, scale: CGFloat)
}

struct CanvasView: View   // (model: EditorModel). Renders handle.render off the main actor (Task.detached with
                          // Data, never CGImage across actors), draws Overlay, maps gestures:
                          // one-finger drag/tap → pointer down/move/up (tool action), double tap → "double",
                          // two-finger pan → pan, pinch → zoom_at, Pencil pressure → pressure, pointer hover → "hover".
                          // Hand tool: one-finger drag pans.
```
Entry views: `App` builds `EditorRootView(model:)` (UI-owned, `UI/Shared/EditorRootView.swift`), which picks
`PadEditorView` or `PhoneEditorView` by horizontal size class / window width (< 700 pt → phone layout). Sheets for
`pendingCommand` (`CommandSheet`), the palette (`CommandPaletteView`), templates, export, the importer and errors
(alert) are attached in `EditorRootView`; presenting is a `.fullScreenCover` with `PresentView(model: presenter)`.
Menu bar (`App/FigCraftCommands.swift`, Core-owned) reads the model through `@FocusedValue(\.editorModel)`;
`EditorRootView` publishes `.focusedSceneValue(\.editorModel, model)` (key declared in `Core/FocusedValues.swift`).

`CommandCatalog` (Core, `static let shared`): wraps `commandCatalog()`, `menuLayout()`, `toolGroups()`:
`menus`, `toolGroups`, `command(id)`, `label(id)`, `shortcut(id) -> KeyboardShortcut?`, `params(id)`,
`needsParams(id) -> Bool` (any non-optional field), `isExcluded(id)`.

UI requests (`take_ui_requests`) handled by Core: `present`/`preview` → `startPresenting(from: data.start)`;
`home.templates` → `showTemplates`; `dialog.saveAs` → `showExport`; `layers.rename` → UI rename field; anything else →
toast with the kind (never a crash).

## 5. Accessibility identifiers (UI tests drive only these)

`tool.<id>` (toolbar), `panel.<id>` (`panel.layers`, `panel.assets`, `panel.design`, `panel.prototype`,
`panel.inspect`), `command.<id>` (every surface that shows a command: menus, context menus, palette rows, buttons),
`section.<name>` (inspector sections: `section.position`, `section.layout`, `section.appearance`, `section.fill`,
`section.stroke`, `section.effects`, `section.text`, `section.export`, `section.page`, `section.interactions`,
`section.flows`), `control.<propKey>` (inspector fields, key = node.set prop key, e.g. `control.x`, `control.opacity`),
`layer.<id>`, `page.<id>`, `canvas`, `present`, `present.back`, `present.close`, `present.restart`,
`palette`, `palette.search`, `template.<id>`, `undo`, `redo`, `demoReady` (hidden marker, present once demo seeding
finished), `toast`. Chrome ids used by the UI and tests: `phone.layers|design|prototype`, `sheet.close`,
`sidebar`, `sidebar.toggle`, `inspector`, `inspector.toggle`, `toolbar`, `toolstrip`, `palette.open|list|done`,
`menu.more`, `menu.palette`, `share`, `export.*`, `templates.*`, `error.ok`, `rename.ok`, `layers.*`, `pages.*`,
`assets.*`, `flow.*`, `interaction.add`, `cmdSheet.*` (command parameter sheet), `inspectCode.*`, `comments`,
`comments.open`, `versions`, `section.header|grids|properties|code|selectionColors|protoSettings|styles|variables`.
Widget ids must never look like command ids (no `panel.` ids that are also commands → use the
LeftPanel/RightPanel raw values above; check-command-ids enforces it).

## 6. Demo (`-FigCraftDemo`)

`DemoSeeder` (Core): new documents in demo mode = `DocumentHandle.fromTemplate(templateId: "mobile-app", dark:)`,
then through engine commands: `proto.flow.add` on the first top-level frame, `proto.interaction.add` click-navigate
between the first two frames (`{id: <a button-like layer in frame 1, else frame 1>, dest: frame2}`) and a back action
on frame 2, `select.set` the first frame, `view.zoomFit`. Then `isDemoReady = true` (shows the `demoReady` marker). UI
tests launch with `-FigCraftDemo` and create a new document from the document browser (identifier of the system
"Create Document" button) — the Core also honours `-FigCraftDemoAutoCreate`, which opens a new demo document at launch
without the browser (used by tests to skip the system browser).

## 7. Panels and menu bar (cookbook §4 rules, 2026-10-24)

Rules: (1) every desktop panel exists and opens from the trailing panel menu (`panels.menu`) and the Window menu;
panels can be added, hidden, collapsed and stacked/reordered (Figma/Photoshop style), arrangement persisted per device
(`@AppStorage("figcraft.panels")`, JSON list of `{id, collapsed}` per column); iPhone shows them as sheets. A panel
entry that opens nothing is a bug; the panel tour opens and acts on every panel. (2) Panel-owned actions sit in the
panel header, not the global toolbar. (3) iPad menu bar = iPadOS system groups with the desktop menus/items inserted in
desktop order; Window and Help last.

Panel catalog (id → desktop source → header actions): `layers` (+ Pages; layers.rs → `command.page.add`, collapse all),
`assets` (assets_panel.rs → create component, search), `styles` (→ create style), `variables` (→ create collection /
variable), `design` (right.rs), `prototype` (proto_panel.rs → add flow), `inspect` (Dev Mode, right.rs inspect),
`comments` (→ add comment, filter), `versions` (version history → save version), `libraries` (`panel.libraries`
request). Window menu: one toggle per panel, identifier `window.panel.<id>`; panel menu items `panels.toggle.<id>`;
panel headers `panelHeader.<id>`, collapse `panelHeader.<id>.collapse`. `view.layers|assets|design|prototype` UI
requests/commands show the matching panel.

Current non-compliance (to fix when the hold lifts):
- Panels are fixed tab strips (leading: Layers/Assets; trailing: Design/Prototype/Inspect): no add/hide/collapse,
  no stacking or reordering, nothing persisted; no `panels.menu`.
- Window menu has no panel entries; `view.layers|assets|design|prototype` not verified to open their panel.
- Comments and Version history are sheets opened from the global top bar / overflow (`comments.open`, `menu.versions`),
  not panels; their actions should move into their panel headers.
- Styles and Variables live as sections inside Assets; create actions sit in section rows/+ menus, not a panel header.
- Libraries panel missing (`panel.libraries` request only toasts).
- Canvas-only fullscreen mode (`control.fullscreen`, `control.fullscreen.exit`, ⌃⌘F, Esc) not implemented.
- Menu bar already merges File/Edit/View/Help into the system groups and adds Object…Tools as custom menus; Window/Help
  ordering not yet verified on device.

## 8. Productive and clean (cookbook §0b, 2026-10-24)

Speed: every frequent action ≤ 1 tap from the canvas; every desktop shortcut on a hardware keyboard with the same keys
(engine `keymap.rs` KEYS: V, K, H, F/A, ⇧S, S, R, L, ⇧L, O, P, ⇧P, T, C, ⇧M, ⌘G, ⌘⌥K, ⇧A auto layout, ⌘D, ⌘[ ⌘]…);
⌘K opens the palette; context menus on layers, frames, canvas selection, page/style/variable rows; drag & drop (layer
reorder/reparent, image/SVG files onto the canvas, rows between panels where the desktop allows it); two-finger tap =
undo, three-finger tap = redo (two-finger double tap stays zoom-to-fit); Apple Pencil draws with Pen/Pencil, finger
pans; scrubbable numeric fields; customizable toolbar (`ToolbarCustomization` / `.toolbar(id:)`); remember last tool,
panel layout, fill/stroke values and zoom per document; multiple windows (scenes) on iPad. Clean: system components,
SF Symbols, semantic colours, one primary action per area, the rest in menus, panel headers and the palette; no custom
chrome. The Haiku feature pass reports taps-to-do for the top 10 workflows: draw a frame, add text, rectangle + fill
colour, auto layout on a selection, create component, insert instance, add a prototype interaction, present, export
PNG, rename/reorder layers.

Current gaps (fix when the hold lifts):
- Hardware shortcuts: only single-key tool shortcuts (hidden buttons) and menu-bar items with ⌘ chords; the rest of
  KEYS (⇧-letter tools, auto layout ⇧A, grouping, arrange, zoom ⇧0/⇧1/⇧2) not mapped; no ⌘K palette shortcut.
- No two-finger-tap undo / three-finger-tap redo gestures (two-finger double tap = fit exists).
- No drag & drop: layer rows can't be reordered/reparented by dragging; no file drops onto the canvas.
- Context menus exist on layer and page rows; missing on the canvas selection and on style/variable rows.
- Toolbar not customizable; last tool, panel layout and values are not remembered (only prototype present options).
- Multi-window: `DocumentGroup` allows several scenes, but per-window state (panels, tool) is not separated or kept.
- Pencil: pressure + finger-pans-while-Pencil exist for Pen/Pencil; no Pencil hover/squeeze/double-tap tool switch.

## 9. Media in and new-from-media (cookbook §0b, 2026-10-24)

Start a new file from an image or design file (`.fig`, `.svg`, `.png`, `.jpg`, `.heic`; new document whose first frame
is sized to the image, via `file.open` data for design files and `file.new` + `file.import` for images) and
place/import into the current context: selected frame or shape fill (`file.placeImage` / image fill via `node.set`),
else the current page at the viewport centre (`file.import` with `x`,`y`). Sources: camera roll (`PhotosPicker`),
Files/iCloud (`fileImporter`), drag & drop onto the canvas, paste (⌘V with image/SVG data). Entry points: new-document
flow, Layers and Assets panel headers, File ▸ Place image / Import, ⌘K palette, canvas context menu. Ids:
`media.photos`, `media.files`, `newFromMedia`.

Current gaps: only `fileImporter` → `file.import` from the editor; no `PhotosPicker`, no new-document-from-media,
no drop or paste of images, no image-fill placement into the selected shape.
