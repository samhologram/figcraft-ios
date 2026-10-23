# FigCraft for iPad and iPhone

Native SwiftUI app on the unchanged FigCraft Rust engine (UniFFI bridge in `bridge/`). Fork rules: `../FORK.md`.
Contracts between the bridge, the Swift core and the UI: `docs/CONTRACT.md`.

## UX direction

Apple's Human Interface Guidelines first (system components, Liquid Glass materials, Dynamic Type, keyboard and
pointer, Apple Pencil, dark and light). Faithful to the desktop app's mental model: the same tools (Move, Frame,
Section, Slice, Rectangle…Star, Pen, Pencil, Shape builder, Text, Comment, Hand, Scale), the same panels (Layers and
Pages, Assets; Design, Prototype, Inspect), the same menu structure (File, Edit, View, Object, Text, Arrange, Vector,
Plugins, Preferences, Libraries, Help) generated from the engine catalog.

**Reference app: Figma for iPad / iPhone** (the top-rated interface-design app on the App Store, about 4.6★ from
~20 k ratings in 2026; the desktop FigCraft already mirrors Figma's layout). Figma's mobile app is strongest at
browsing files, playing prototypes and commenting; for touch *editing* conventions we also follow **Linearity Curve**
and **Affinity Designer for iPad** (the cookbook's vector references). Behaviour and look only, clean-room: no
third-party assets, icons or code; icons are SF Symbols.

Conventions taken from it:

1. **Files first.** The app opens on the system document browser (recents, Files locations); a file opens full-screen
   onto the canvas; Back returns to the browser.
2. **Canvas is the whole window.** Pinch to zoom, two-finger drag to pan, double-tap with two fingers zooms to fit;
   one finger acts with the current tool (Move selects and drags). Apple Pencil draws with Pen/Pencil; a finger never
   draws while a Pencil is in use.
3. **iPad: floating bottom toolbar** with the tool groups (Move, Frame, Shapes, Pen, Text, Comment); a long press on
   a group opens its flyout, as on the desktop.
4. **iPad: Layers/Pages sidebar on the leading edge, inspector with Design / Prototype / Inspect tabs on the trailing
   edge**, both collapsible; sections appear under the same conditions as on the desktop (Text only for text,
   Auto layout for frames…).
5. **iPhone: bottom tool strip + sheets.** Layers, Design and Prototype open as sheets with medium/large detents so
   the canvas stays visible above them.
6. **Play button in the top bar** presents the prototype full-screen (from the selected frame, else the first flow):
   tap hotspots to navigate, swipe from the leading edge or tap Back to go back, Close returns to the editor; a tap
   where nothing reacts flashes the hotspots.
7. **Top bar**: back to documents, file name, undo / redo, Play, Share (export PNG/SVG/PDF), and a "…" overflow with
   the full menu (generated from the desktop catalog) and the command palette (Quick actions).
8. **Numeric fields scrub**: drag on a field label to change the value; a drag is one undo step.
9. **Context menu (long press) on layers and canvas selection** with the desktop's Object/Arrange commands.
10. **New from template** in the document browser's create flow, matching the desktop's starter templates.

Per-idiom degradation (iPad windows are resizable): full layout (sidebar + canvas + inspector) → inspector and sidebar
as overlays/sheets when the window is narrower than 1000 pt → iPhone layout (tool strip + sheets) below 700 pt.
Nothing falls off screen: tool strips scroll as the last resort, labels never wrap mid-word.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer PATH="$HOME/.cargo/bin:$PATH"
apple/scripts/build-xcframework.sh --sim-only --debug
cd apple && xcodegen generate
xcodebuild build-for-testing -scheme FigCraft -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd
```

Gates before every commit: `cd apple/bridge && cargo test && cargo clippy --all-targets -- -D warnings`,
`apple/scripts/check-command-ids.sh`, `apple/scripts/tool-coverage.sh`, `apple/scripts/feature-coverage.sh --check`.

Demo: launch with `-FigCraftDemo` — new documents are built from the engine's "Mobile app" template with a prototype
flow and click-through interactions added through engine commands.

## Upstream notes

Engine gaps found by the port (worked around in the bridge or Swift; to send upstream):

- `figcraft_text` scans no font directory on iOS (`system_font_dirs` has no `target_os = "ios"` arm); the app feeds
  system fonts through `fontdb::load_font_bytes`.
- The prototype player (`crates/ui-egui/src/present.rs` `Presenter`) lives in the egui crate; the bridge carries an
  egui-free port. An engine-level player would let every front end share it.
- No `disabled_reason` / can-run query for commands; the bridge approximates it.
