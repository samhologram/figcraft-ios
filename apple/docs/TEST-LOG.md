# FigCraft iOS test log

| Date | Build | Device | Suite | Result | Notes |
|---|---|---|---|---|---|
| 2026-10-24 | 31d0c520 (build/dd) | iPad Pro 11-inch (M5), shared | FigCraftTests (unit) | 9/9 pass | first simulator run, no crash |
| 2026-10-24 | 31d0c520 | iPad Pro 11-inch (M5) | FigCraftUITests testScenarioDark / testScenarioLight | pass (154 s / 153 s) | `-notes` attachments not read (results cleaned): hollow pass not ruled out |
| 2026-10-24 | uncommitted dock patch | generic iOS Simulator | `xcodebuild build-for-testing` | pass | app and test targets compile; runtime, dock UI assertions, and simulator tours still pending |
| 2026-10-24 | uncommitted dock patch | host bridge | `cargo test`; `cargo clippy --all-targets -- -D warnings` | pass | 32 Rust tests, 0 failures; Clippy clean |
| 2026-10-24 | uncommitted dock patch | host catalog | command IDs; tool coverage; feature coverage `--check` | pass | 149 listed command IDs, 64 used in Swift; 24 desktop tools/panels mapped; generated feature coverage document added |
| 2026-10-24 | uncommitted dock patch | iPad Pro 11-inch (M5) | FigCraftTests | 9/9 pass | Luna validation on current dock build |
| 2026-10-24 | uncommitted dock patch | iPad Pro 11-inch (M5) | focused PanelDockUITests | setup failed twice; rerun pending | First run waited at DocumentGroup browser for `demoReady`; second selected an unhittable duplicate `newDocument` element. Test now chooses a hittable New Design button and requires `demoReady` plus `canvas` before dock assertions. No dock behavior conclusion yet. |
| 2026-10-24 | uncommitted dock patch | iPad Pro 11-inch (M5) | focused PanelDockUITests | setup failed on third run; rerun pending | Dynamic Files browser changed during all-button enumeration and XCTest reported a stale indexed snapshot before New Design was tapped. A shared exact-label query helper now avoids that enumeration; compiled in the final generic test bundle. Dock assertions still have not run. |
| 2026-10-24 | uncommitted dock patch | generic iOS Simulator | native Browse fixture + dock/story tests | build pass, runtime pending | Shared opener now selects local storage through Browse, then requires foreground hittable canvas with browser gone and `demoReady`. No dock or opacity story assertions have executed yet. |
| 2026-10-24 | post-300b8cce document fix | generic iOS Simulator | `build-for-testing` including DocumentLifecycleTests | build pass, runtime pending | Background-safe new/read/snapshot, validated seeded Untitled readback and `demoReady` unit cases compile; no simulator result yet. |
| — | — | — | Tool/Panel/Command tours, iPhone, Haiku feature pass | not run | on hold |
