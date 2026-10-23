//! Tests of the document handle and the static tables.

use super::*;

fn run(h: &DocumentHandle, id: &str, p: Value) -> Value {
    serde_json::from_str(&h.execute(id.into(), p.to_string()).unwrap()).unwrap()
}

#[test]
fn catalog_menus_tools_templates_load() {
    assert!(command_catalog().len() > 300);
    assert!(menu_layout().iter().any(|s| s.title == "File"));
    let groups = tool_groups();
    assert!(groups.len() >= 5 && groups[0].tools[0].command == "tool.move");
    assert!(templates().len() >= 8);
    assert!(command_params("shape.rectangle".into()).iter().any(|f| f.key == "width"));
    assert!(engine_version().starts_with("figcraft-apple"));
}

#[test]
fn new_document_state_and_history() {
    let h = DocumentHandle::new_document("Sketch".into(), true);
    let s = h.state();
    assert_eq!((s.name.as_str(), s.page_count, s.can_undo, s.dirty), ("Sketch", 1, false, false));
    assert_eq!(s.tool, "move");
    let (h0, r0) = (s.history_id, s.revision);
    let r = run(&h, "shape.rectangle", json!({"x": 10, "y": 10, "width": 100, "height": 50}));
    assert!(r.is_object());
    let s = h.state();
    assert!(s.can_undo && s.dirty);
    assert_ne!(s.history_id, h0);
    assert_ne!(s.revision, r0);
    assert!(s.undo_label.is_some());
    let h1 = s.history_id;
    // A query does not record a step.
    run(&h, "node.get", json!({"id": h.layers()[0].id}));
    assert_eq!(h.state().history_id, h1);
    assert!(h.undo().unwrap());
    let s = h.state();
    assert!(!s.can_undo && s.can_redo && s.redo_label.is_some());
    assert_ne!(s.history_id, h1);
    assert!(h.redo().unwrap());
    assert!(!h.redo().unwrap());
}

#[test]
fn interaction_is_one_step_and_layers_list() {
    let h = DocumentHandle::new_document("L".into(), false);
    let r = run(&h, "shape.rectangle", json!({"x": 10, "y": 10, "width": 100, "height": 50}));
    let id = r["id"].as_u64().unwrap();
    let depth = h.state().history_id;
    h.begin_interaction("Drag".into()).unwrap();
    for x in [20, 30, 40] {
        run(&h, "node.set", json!({"ids": [id], "props": {"x": x}}));
    }
    h.end_interaction().unwrap();
    assert_eq!(h.state().history_id, depth + 1);
    let layers = h.layers();
    assert_eq!(layers.len(), 1);
    assert_eq!((layers[0].kind.as_str(), layers[0].depth, layers[0].parent), ("rectangle", 0, None));
    assert!(h.node_json(id).unwrap().contains("\"x\""));
    // A missing node reads as JSON null.
    assert_eq!(h.node_json(999_999).unwrap(), "null");
}

#[test]
fn save_open_round_trip() {
    let h = DocumentHandle::new_document("Round".into(), false);
    run(&h, "shape.rectangle", json!({"x": 0, "y": 0, "width": 80, "height": 80}));
    assert!(h.state().dirty);
    let bytes = h.save_bytes().unwrap();
    assert!(!h.state().dirty);
    let h2 = DocumentHandle::open(bytes, "Round.figcraft".into()).unwrap();
    assert_eq!(h2.state().name, "Round");
    assert_eq!(h2.layers().len(), 1);
    assert!(!h2.state().dirty);
    assert!(DocumentHandle::open(b"not a file".to_vec(), "x.figcraft".into()).is_err());
}

#[test]
fn render_sizes_and_viewport() {
    let h = DocumentHandle::from_template("mobile-app".into(), false).unwrap();
    h.set_viewport(400.0, 300.0);
    let img = h.render(800, 600, 2.0).unwrap();
    assert_eq!((img.width, img.height, img.rgba.len()), (800, 600, 800 * 600 * 4));
    assert!(h.render(0, 5, 1.0).is_err());
    assert!(h.render(100_000, 100_000, 1.0).is_err());
    let t = h.thumbnail(128).unwrap();
    assert!(t.width.max(t.height) == 128);
    // View operations change the revision and clamp zoom.
    let r = h.state().revision;
    h.zoom_at(1e9, 10.0, 10.0);
    assert!(h.state().zoom <= figcraft_engine::ViewState::MAX_ZOOM);
    h.set_view(f64::NAN, 0.0, 1.0);
    h.pan(5.0, 5.0);
    assert_ne!(h.state().revision, r);
    assert!(DocumentHandle::from_template("nope".into(), false).is_err());
}

#[test]
fn drawing_with_the_pointer_is_one_undo_step() {
    let h = DocumentHandle::new_document("P".into(), false);
    h.set_viewport(500.0, 500.0);
    h.execute("tool.rectangle".into(), "{}".into()).unwrap();
    assert_eq!(h.state().tool, "rectangle");
    let before = h.state().history_id;
    h.pointer("down".into(), 100.0, 100.0, false, false, false, false, None).unwrap();
    h.pointer("move".into(), 160.0, 150.0, false, false, false, false, None).unwrap();
    h.pointer("move".into(), 200.0, 180.0, false, false, false, false, Some(0.5)).unwrap();
    h.pointer("up".into(), 200.0, 180.0, false, false, false, false, None).unwrap();
    assert_eq!(h.layers().len(), 1);
    assert_eq!(h.state().history_id, before + 1);
    assert!(!h.overlay().selection.is_empty());
    assert!(h.overlay().bounds.is_some());
    assert!(h.pointer("tap".into(), 1.0, 1.0, false, false, false, false, None).is_err());
    assert!(h.pointer("down".into(), f64::NAN, 1.0, false, false, false, false, None).is_err());
}

#[test]
fn text_editing_keys_and_insert() {
    let h = DocumentHandle::new_document("T".into(), false);
    h.set_viewport(500.0, 500.0);
    h.execute("tool.text".into(), "{}".into()).unwrap();
    h.pointer("down".into(), 100.0, 100.0, false, false, false, false, None).unwrap();
    h.pointer("up".into(), 100.0, 100.0, false, false, false, false, None).unwrap();
    if h.state().editing_text {
        h.insert_text("Hello".into()).unwrap();
        assert!(h.key("Backspace".into(), false, false, false).unwrap());
        assert!(h.overlay().caret.is_some());
    }
    // Unknown key names are not handled, not an error.
    assert!(h.key("F13".into(), false, false, false).is_ok());
}

#[test]
fn exports_and_errors() {
    let h = DocumentHandle::new_document("E".into(), false);
    assert!(h.export_png(vec![], 1.0).is_err());
    run(&h, "node.create", json!({"type": "frame", "x": 0, "y": 0, "width": 50, "height": 50}));
    let png = h.export_png(vec![], 2.0).unwrap();
    assert!(png.starts_with(&[0x89, b'P', b'N', b'G']));
    assert!(String::from_utf8_lossy(&h.export_svg(vec![]).unwrap()).contains("<svg"));
    assert!(h.export_pdf().unwrap().starts_with(b"%PDF"));
    assert!(h.execute("no.such.command".into(), "{}".into()).is_err());
    assert!(h.execute("shape.rectangle".into(), "{not json".into()).is_err());
}

#[test]
fn disabled_reason_never_runs_the_command() {
    let h = DocumentHandle::new_document("D".into(), false);
    assert!(h.disabled_reason("no.such".into()).is_some());
    assert!(h.disabled_reason("window.new".into()).is_some());
    assert!(h.disabled_reason("edit.undo".into()).is_some());
    assert!(h.disabled_reason("shape.rectangle".into()).is_none());
    // Not run: still nothing in the document.
    assert!(h.layers().is_empty() && !h.state().can_undo);
    // Selection commands need a selection.
    assert!(h.disabled_reason("node.delete".into()).is_some() || figcraft_engine::find_command("node.delete").is_none());
    let r = run(&h, "shape.rectangle", json!({"x": 0, "y": 0, "width": 10, "height": 10}));
    run(&h, "select.set", json!({"ids": [r["id"]]}));
    assert!(h.disabled_reason("edit.undo".into()).is_none());
    assert!(h.execute("window.new".into(), "{}".into()).is_err());
}

#[test]
fn ui_requests_are_drained_and_poisoned_locks_recover() {
    let h = DocumentHandle::new_document("U".into(), false);
    let _ = h.execute("file.newFromTemplate".into(), "{}".into());
    let reqs = h.take_ui_requests();
    assert!(reqs.iter().any(|r| r.kind == "home.templates"));
    assert!(h.take_ui_requests().is_empty());
    // Poison the lock from another thread: calls keep working.
    let h2 = h.clone();
    let _ = std::thread::spawn(move || {
        let _g = h2.inner.lock().unwrap();
        panic!("poison");
    })
    .join();
    assert_eq!(h.state().name, "U");
    assert!(h.execute("shape.rectangle".into(), r#"{"x":0,"y":0,"width":5,"height":5}"#.into()).is_ok());
}

#[test]
fn junk_params_never_panic_the_bridge() {
    let h = DocumentHandle::new_document("J".into(), false);
    let junk = ["{}", "[]", "null", "1", "\"x\"", r#"{"ids":"a"}"#, r#"{"id":-1}"#, r#"{"x":1e999}"#, r#"{"ids":[1,2,3],"props":5}"#];
    for c in figcraft_engine::all_commands() {
        if excluded_reason(c.id).is_some() || c.id.starts_with("file.") || c.id.starts_with("collab.") || c.id.starts_with("plugin.") || c.id.starts_with("library.") || c.id.starts_with("app.") {
            continue;
        }
        for p in junk {
            let _ = h.execute(c.id.into(), p.into());
        }
    }
    assert!(h.state().page_count >= 1);
    let _ = h.render(64, 64, 1.0).unwrap();
}
