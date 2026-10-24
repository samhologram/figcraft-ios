# FigCraft: user-story UX validation, iPadOS and iOS

Luna's dock runs have not reached an editor: the initial run stayed in the document browser, a duplicate New Design element was unhittable, and a dynamic Files-browser query produced a stale snapshot. The current shared fixture navigates Browse to On My iPad/iPhone, selects the FigCraft folder when shown, and requires a foreground hittable canvas with the browser gone plus demoReady. This fixture compiles but has not been run. These setup failures are not proof of a product dock failure. CONTRACT still lists foreign editable-copy, fullscreen, Libraries panel and several import/gesture gaps; confirm current source/runtime before closing them.

## Story-to-test matrix

| User goal | iPadOS executable case | iOS executable case / gap | Required observable result |
|---|---|---|---|
| Edit a selected design layer, then inspect prototype behavior | `UserStoryUITests/testEditLayerOpacityUndoRedoAndPrototypePortrait` (new) | Same selector: Layers/Design sheets replace iPad overlays | Numeric opacity persists after panel reopen; undo/redo restores exact values; Prototype content exists; selected layer preserved |
| Open/reopen/collapse selected inspector tab | `PanelDockUITests/testAddMenuKeepsSelectedPanelVisible` | Existing case returns early on phone: NOT phone dock coverage; new opacity story verifies phone tab/content | New/reopened Prototype tab visible and expanded |
| Dark/light, prototype presentation, catalog tours | `FigCraftUITests/testScenarioDark`, `testScenarioLight`; panel/tool/command tours | Same portrait suites | Read all notes; presentation launch alone does not prove working navigation |
| Persist/import/share design | Full UI roundtrip story pending | Same gap | `.figcraft` reopen retaining edit, original unchanged, reusable native copy |
| Narrow/wide layout | New portrait story on shared 834pt iPad exercises overlays; landscape panel tour | Phone sheets exercised in new story | Reachable controls and stable selected artwork; do not call portrait Stage Manager testing |

## Execution and evidence rules

Astra authored/reviewed these cases on 2026-10-24; Luna executes. New cases are **not yet runtime validated**. Sol owns production fixes and generic `build-for-testing`; regenerate XcodeGen to include new files. Use current `apple/build/dd`, never an old `dd-core` bundle.

1. Shared iPad `81A653B3-9027-4C16-8335-320CB937C66C` first: portrait, then landscape, then genuinely resized narrow window if available. Shared iPhone `FF7E37C5-12E6-483D-8887-D09D18EEB4A4` only after iPad fixes. One simulator under workspace `.sim.lock`; no build while holding it.
2. Run `-only-testing:FigCraftUITests/<Class>/<method>` with the names above, `-collect-test-diagnostics never`. No screenshots. Retain assertion text, hierarchy/frames, logs and notes. Remove app/runner after each run per cookbook.
3. Record build path/commit, device, window size, orientation, appearance, fixture/permission state, exact selector, completed/failed/aborted, first failing step and full error. A skipped case, early return, missing fixture or NOT-REACHED is **not** a passed workflow.
4. Photos integration needs a known seeded asset and explicit granted/denied/limited states. Native-copy tests need known source bytes/hash, produced native URL and repeat-open identity. Demo data proves editing UI only. Never touch a personal library fixture.
5. Compare tap count only for the same route and setup. Review clipped/hittable frames, selection traits, return-to-canvas, sheet dismissal and contextual actions. System menu rows under 44pt alone are not UX bugs. Menu plus hardware shortcut is legitimate duplication; the user rejected parallel floating panel launchers.

## Remaining cross-platform acceptance work

- Reorder/stack and collapsed/selected panel state across app termination **without reset launch arguments**; PhotoCraft already has a reusable persistence case. Repeat Window/menu route separately from dock Add; selected tab must scroll into view when already selected, collapsed or previously hidden.
- Real narrow-window resizing (Stage Manager/Split View), landscape transitions mid-edit, dark/light and large Dynamic Type. Orientation alone is not proof of resizable-window support. Accessibility evidence cannot establish contrast/color correctness without render inspection; no screenshots requested.
- Hardware shortcuts and multi-finger undo/redo must show document changes, not just menu presence. Pencil hover/squeeze/pressure and physical keyboard behavior need an appropriate device pass; list unavailable hardware as unverified, not successful.
- Native document/library persistence and import/export roundtrip beyond available tests, error recovery, permission denial and media relinking. Unsupported features remain tracked gaps.

## Bounded UX review findings

| Priority | Platform | Evidence / reproduction | Interpretation and next action |
|---|---|---|---|
| P1 | iPad / all platforms at risk | Vector shortcut duplicate caused launch crash; earlier runtime used stale dd-core | Root reports source fix + regression; Luna must run current bundle before UX suite |
| P1 | Light iPad | Masking Add → Subject did not create mask; later Crop/Remove failed after cached original absolute path became stale | Root reports repairs; rerun F and tour on fresh current bundle; no cascade counted as separate proven defect |
| P2 | Film iPad | Portrait 834pt tried to find wide dock (`>=900`) | Test setup defect fixed with landscape case and separate portrait sheet story |
| P2 | Fig iPad | Recents browser and duplicate/dynamic New Design queries prevented document creation | Test fixture now chooses a local native Browse location and requires foreground demo canvas; await current run |
| P2 | iOS and iPadOS | Legacy smoke steps often log missing action as notes; iPad-only panel tests skip/return on phone | New strict result stories reduce false green; inspect legacy notes and keep remaining phone gaps explicit |

This report incorporates parent/Luna observations, not an independent runtime pass. Each new failure must be classified as product defect, test defect or unavailable fixture before a production change.

## Focused execution handoff

After the app owner rebuilds the complete test bundle and Luna obtains the shared lock, run from `figcraft-ios/apple` (choose a fresh result path):

```sh
xcodebuild test-without-building -scheme FigCraft -derivedDataPath build/dd \
  -destination 'id=81A653B3-9027-4C16-8335-320CB937C66C' \
  -only-testing:FigCraftUITests/UserStoryUITests/testEditLayerOpacityUndoRedoAndPrototypePortrait \
  -collect-test-diagnostics never -resultBundlePath build/results/story-ipad.xcresult
```

Substitute other exact selectors from the matrix. After iPad fixes pass, repeat applicable cases with destination `id=FF7E37C5-12E6-483D-8887-D09D18EEB4A4` and a distinct result bundle. Use the existing orchestrator lock/uninstall wrapper; this command alone does not acquire the workspace lock. Require the requested test name and a nonzero completed-test count in results: exit zero with zero executed tests is not a pass.

## Phase 2 evidence review (2026-10-24)

- **Film iPad:** read `filmcraft-ios/apple/build/results/luna-story-suite.log`; three requested cases executed and failed. Landscape width precondition passed, but dock `menu.panels` existed and was not hittable. Portrait `menu.more` was absent. Split added a clip (strict assertion passed), then `command.edit.undo` was absent: cut is observed, undo/redo remains unreached. Portrait hierarchy in `/tmp/film-story-attachments/D9415F75-5DA6-4D1D-92CD-75EF5E5C0557.txt` has editing/transport controls but no navigation bar/Undo. Source DemoApp → DemoWindow → EditorScene has no NavigationStack while PadEditorView supplies Undo/More only through toolbar. **P1 fixture-host hypothesis:** demo may omit toolbar navigation host; sent to Film owner. Do not infer an undo-engine defect or generalize to normal DocumentGroup. Landscape dock hit testing needs separate frame evidence.
- **Fig iPad:** read `figcraft-ios/apple/build/results/luna-dock-final.log`: one case executed, failed before demo at dynamic button enumeration with stale element index 10. This is a setup failure; no dock assertions reached. The shared opener now uses native Browse to pick local storage and exact-label New Design lookup, then requires foreground canvas plus demoReady. Its current bundle is compiled, not run. No independent all-buttons opener should be reintroduced.
- **Vector:** latest Luna report confirms six catalog consistency tests passed, including reserved paste shortcut regression. Dock run executed zero tests because test binary lacked that selector. Require regenerated project/current test binary, nonzero count and named selector; a green process exit is not runtime UX proof.
- **Photo:** new phone stories are source-authored only, not compiled/executed. The no-screenshot reusable cases are EditCopy, NewFromPhoto, PlacePhoto, Fullscreen and UserStory S1–S9. Do **not** schedule legacy PhotoCraftUITests/testScreenshotsDark or testScreenshotsLight: their `shot` helper calls XCUIScreen.main.screenshot(), contrary to this run's request.
- **Light:** no new phase-2 runtime evidence reviewed. F and current-original-path tour need Luna rerun; previous reports do not establish success of the rebuilt fixes.
