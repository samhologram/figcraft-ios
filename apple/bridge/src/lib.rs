//! UniFFI bridge between the FigCraft engine and the Swift app (iOS / iPadOS).
//!
//! The API is specified in `apple/docs/CONTRACT.md` section 3; names and types here match it.
//! Never panics on input: engine calls run under `catch_unwind` as a last-resort guard.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, PoisonError};

use base64::Engine as _;
use figcraft_doc::{Document, ExportFormat, NodeId, PrintSettings};
use figcraft_engine::tools::{PointerEvent, PointerKind};
use figcraft_engine::Session;
use serde_json::{Value, json};

mod info;
pub mod params_doc;
mod present;

pub use present::{FlowInfo, PresentState, Presenter};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{message}")]
    Failed { message: String },
}

pub(crate) fn fail(message: impl Into<String>) -> BridgeError {
    BridgeError::Failed { message: message.into() }
}

#[derive(uniffi::Record)]
pub struct CommandInfo {
    pub id: String,
    pub label: String,
    /// e.g. ["Edit", "Copy as"]; empty = not in menus.
    pub menu: Vec<String>,
    pub shortcut: Option<String>,
    pub params: String,
    pub undoable: bool,
}

#[derive(uniffi::Record)]
pub struct MenuSection {
    pub title: String,
    pub items: Vec<MenuEntry>,
}

#[derive(uniffi::Record)]
pub struct MenuEntry {
    /// "command" | "separator" | "submenu"
    pub kind: String,
    pub id: String,
    pub label: String,
    pub children: Vec<MenuEntry>,
}

#[derive(uniffi::Record)]
pub struct ToolGroup {
    pub key: String,
    pub name: String,
    pub tools: Vec<ToolInfo>,
}

#[derive(uniffi::Record)]
pub struct ToolInfo {
    pub id: String,
    pub command: String,
    pub label: String,
    pub shortcut: Option<String>,
}

/// Structured view of a params doc; best effort.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ParamField {
    /// "" = free-form remainder.
    pub key: String,
    /// "number","integer","bool","choice","string","ids","id","color","json".
    pub kind: String,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub default_json: Option<String>,
    pub choices: Vec<String>,
    pub label: String,
    pub is_optional: bool,
    pub doc: String,
}

#[derive(uniffi::Record)]
pub struct DocState {
    pub name: String,
    pub page: u64,
    pub page_count: u32,
    pub selection: Vec<u64>,
    pub tool: String,
    pub can_undo: bool,
    pub can_redo: bool,
    pub undo_label: Option<String>,
    pub redo_label: Option<String>,
    pub revision: u64,
    pub history_id: u64,
    pub dirty: bool,
    pub zoom: f64,
    pub center_x: f64,
    pub center_y: f64,
    pub editing_text: bool,
    pub vector_editing: bool,
    pub message: Option<String>,
}

#[derive(uniffi::Record)]
pub struct PageInfo {
    pub id: u64,
    pub name: String,
    pub is_divider: bool,
}

#[derive(uniffi::Record)]
pub struct LayerRow {
    pub id: u64,
    pub parent: Option<u64>,
    pub depth: u32,
    pub name: String,
    pub kind: String,
    pub visible: bool,
    pub locked: bool,
    pub has_children: bool,
    pub selected: bool,
}

#[derive(Clone, Copy, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(uniffi::Record)]
pub struct Overlay {
    pub selection: Vec<Rect>,
    pub bounds: Option<Rect>,
    pub hover: Option<Rect>,
    pub marquee: Option<Rect>,
    pub caret: Option<Rect>,
    pub guides: Vec<Rect>,
}

#[derive(uniffi::Record)]
pub struct RenderedImage {
    pub width: u32,
    pub height: u32,
    /// RGBA8 PREMULTIPLIED (tiny-skia data as is), stride = width * 4.
    pub rgba: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct UiRequest {
    pub kind: String,
    pub data_json: String,
}

#[derive(uniffi::Record)]
pub struct TemplateInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub kind: String,
    pub size: String,
}

/// What changes when the undo/redo stacks move.
type HistorySig = ((usize, usize), usize, usize);

pub(crate) struct Inner {
    pub(crate) session: Session,
    revision: u64,
    history_id: u64,
    history_sig: HistorySig,
    /// `set_viewport` was called at least once.
    viewport_set: bool,
}

fn top_ptr(d: Option<&figcraft_engine::HistoryEntry>) -> usize {
    d.map_or(0, |h| Arc::as_ptr(&h.doc) as *const () as usize)
}

impl Inner {
    fn new(session: Session) -> Self {
        let sig = Self::sig(&session);
        Inner { session, revision: 1, history_id: 1, history_sig: sig, viewport_set: false }
    }

    fn sig(s: &Session) -> HistorySig {
        match s.ds() {
            Ok(ds) => (s.undo_depth(), top_ptr(ds.history.undo.last()), top_ptr(ds.history.redo.last())),
            Err(_) => ((0, 0), 0, 0),
        }
    }

    /// Bump `history_id` when the undo/redo stacks moved since the last look.
    fn sync_history(&mut self) {
        let sig = Self::sig(&self.session);
        if sig != self.history_sig {
            self.history_sig = sig;
            self.history_id += 1;
        }
    }

    fn touch(&mut self) {
        self.revision += 1;
        self.sync_history();
    }
}

#[derive(uniffi::Object)]
pub struct DocumentHandle {
    inner: Mutex<Inner>,
}

pub(crate) fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    let text = payload.downcast_ref::<&str>().map(|s| (*s).to_string()).or_else(|| payload.downcast_ref::<String>().cloned());
    format!("internal error: {}", text.unwrap_or_else(|| "the engine panicked".into()))
}

fn parse_params(params_json: &str) -> Result<Value, BridgeError> {
    if params_json.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(params_json).map_err(|e| fail(format!("params_json is not valid JSON: {e}")))
}

fn rect_of(r: figcraft_geom::Rect) -> Rect {
    Rect { x: r.x0, y: r.y0, width: r.width(), height: r.height() }
}

/// Largest render the bridge makes (pixels).
const MAX_SIDE: u32 = 16_384;
const MAX_PIXELS: u64 = 80_000_000;

pub(crate) fn pix_image(p: &figcraft_render::Pixmap) -> RenderedImage {
    RenderedImage { width: p.width(), height: p.height(), rgba: p.data().to_vec() }
}

fn check_size(w: u32, h: u32) -> Result<(), BridgeError> {
    if w == 0 || h == 0 || w > MAX_SIDE || h > MAX_SIDE || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err(fail(format!("unsupported image size {w}x{h}")));
    }
    Ok(())
}

/// Run `f` catching panics (for work outside the lock).
pub(crate) fn unwinding<T>(f: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(p) => Err(fail(panic_message(p.as_ref()))),
    }
}

/// What a render needs from the session, taken under the lock and used outside it.
struct Snapshot {
    doc: Arc<Document>,
    page: NodeId,
    selection: Vec<NodeId>,
}

impl DocumentHandle {
    fn wrap(session: Session) -> Arc<Self> {
        Arc::new(Self { inner: Mutex::new(Inner::new(session)) })
    }

    /// Run `f` with the session locked, turning a panic into an error.
    fn guarded<T>(&self, f: impl FnOnce(&mut Inner) -> Result<T, BridgeError>) -> Result<T, BridgeError> {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match catch_unwind(AssertUnwindSafe(|| f(&mut guard))) {
            Ok(r) => r,
            Err(payload) => Err(fail(panic_message(payload.as_ref()))),
        }
    }

    /// Like [`Self::guarded`] for calls that cannot report an error.
    fn guarded_or<T>(&self, fallback: T, f: impl FnOnce(&mut Inner) -> T) -> T {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        catch_unwind(AssertUnwindSafe(|| f(&mut guard))).unwrap_or(fallback)
    }

    fn snapshot(&self) -> Result<Snapshot, BridgeError> {
        self.guarded(|i| {
            let ds = i.session.ds().map_err(|e| fail(e.to_string()))?;
            Ok(Snapshot { doc: ds.doc.clone(), page: ds.page, selection: ds.selection.clone() })
        })
    }

    fn export_ids(snap: &Snapshot, ids: &[u64]) -> Vec<NodeId> {
        let ids: Vec<NodeId> = ids.iter().map(|i| NodeId(*i)).filter(|i| snap.doc.contains(*i)).collect();
        if !ids.is_empty() {
            return ids;
        }
        if !snap.selection.is_empty() {
            return snap.selection.clone();
        }
        snap.doc.node(snap.page).map(|p| p.children.clone()).unwrap_or_default()
    }

    fn export(&self, ids: &[u64], format: ExportFormat, scale: f64) -> Result<Vec<u8>, BridgeError> {
        let snap = self.snapshot()?;
        let ids = Self::export_ids(&snap, ids);
        let scale = if scale.is_finite() { scale.clamp(0.01, 16.0) } else { 1.0 };
        unwinding(|| figcraft_engine::cmd::file::export_bytes(&snap.doc, &ids, format, scale).map_err(|e| fail(e.to_string())))
    }

    fn new_session(dark: bool) -> Session {
        let mut s = Session::empty();
        s.set_ui_dark(dark);
        s
    }

    fn open_into(mut s: Session, command: &str, params: Value) -> Result<Arc<Self>, BridgeError> {
        let r = catch_unwind(AssertUnwindSafe(|| s.execute(command, &params)));
        match r {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(fail(e.to_string())),
            Err(p) => return Err(fail(panic_message(p.as_ref()))),
        }
        if s.docs.is_empty() {
            return Err(fail("the engine opened no document"));
        }
        Ok(Self::wrap(s))
    }
}

/// Commands the document-per-scene iOS app never runs through the bridge.
fn excluded_reason(id: &str) -> Option<String> {
    params_doc::excluded_commands().into_iter().find(|(e, _)| e == id).map(|(_, r)| r)
}

/// Selection-only commands: their params doc takes `ids` (optional, default the selection).
fn needs_selection(id: &str, params: &str) -> bool {
    if id.starts_with("select.") || id.starts_with("view.") || id.starts_with("tool.") || id.starts_with("page.") {
        return false;
    }
    let p = params.trim_start();
    p.starts_with("{ids?") || p.starts_with("{ids,") || p.starts_with("{ids:") || p.starts_with("{ids}")
}

#[uniffi::export]
impl DocumentHandle {
    /// A new empty document.
    #[uniffi::constructor]
    pub fn new_document(name: String, dark: bool) -> Arc<Self> {
        let name = if name.trim().is_empty() { "Untitled".to_string() } else { name };
        match Self::open_into(Self::new_session(dark), "file.new", json!({"name": name})) {
            Ok(h) => h,
            // Cannot happen (file.new only pushes a document); an empty-document fallback keeps the signature total.
            Err(_) => Self::wrap(Session::new()),
        }
    }

    /// Open `.figcraft` (or `.fig`, `.svg`, an image) bytes; `name` tells the format.
    #[uniffi::constructor]
    pub fn open(data: Vec<u8>, name: String) -> Result<Arc<Self>, BridgeError> {
        let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
        Self::open_into(Session::empty(), "file.open", json!({"data": b64, "name": name}))
    }

    #[uniffi::constructor]
    pub fn from_template(template_id: String, dark: bool) -> Result<Arc<Self>, BridgeError> {
        if figcraft_engine::templates::find(&template_id).is_none() {
            return Err(fail(format!("unknown template `{template_id}`")));
        }
        Self::open_into(Self::new_session(dark), "file.newFromTemplate", json!({"template": template_id}))
    }

    /// The `.figcraft` bytes (with thumbnail and history); marks the document saved.
    pub fn save_bytes(&self) -> Result<Vec<u8>, BridgeError> {
        let (snapshot, doc) = self.guarded(|i| {
            let ds = i.session.ds().map_err(|e| fail(e.to_string()))?;
            Ok((figcraft_engine::cmd::file::FileSnapshot::of(ds), ds.doc.clone()))
        })?;
        let bytes = unwinding(|| snapshot.encode().map_err(|e| fail(e.to_string())))?;
        self.guarded(|i| {
            // Only what was encoded counts as saved: edits made meanwhile stay unsaved.
            if let Ok(ds) = i.session.ds_mut()
                && Arc::ptr_eq(&ds.doc, &doc)
            {
                ds.mark_saved();
            }
            i.touch();
            Ok(())
        })?;
        Ok(bytes)
    }

    /// Run a command by id with JSON params; returns the result JSON.
    pub fn execute(&self, id: String, params_json: String) -> Result<String, BridgeError> {
        let params = parse_params(&params_json)?;
        if let Some(why) = excluded_reason(&id) {
            return Err(fail(format!("`{id}` is not available on iOS: {why}")));
        }
        if id == "file.newFromTemplate" && params.get("template").is_some() {
            return Err(fail("`file.newFromTemplate` with a template is not available here: create a document from the template instead"));
        }
        self.guarded(|i| {
            let r = i.session.execute(&id, &params);
            i.touch();
            r.map(|v| v.to_string()).map_err(|e| fail(e.to_string()))
        })
    }

    /// `None` = can run. Best effort; never runs the command.
    pub fn disabled_reason(&self, id: String) -> Option<String> {
        if let Some(why) = excluded_reason(&id) {
            return Some(format!("not available on iOS: {why}"));
        }
        self.guarded_or(Some("internal error".to_string()), |i| {
            let Some(spec) = figcraft_engine::find_command(&id) else { return Some(format!("unknown command `{id}`")) };
            let Ok(ds) = i.session.ds() else { return Some("no document".to_string()) };
            if spec.history
                && let Some(why) = i.session.active_read_only()
            {
                return Some(why.to_string());
            }
            if ds.preview.is_some() && spec.history {
                return Some(figcraft_engine::PREVIEW_READ_ONLY.to_string());
            }
            if needs_selection(&id, spec.params) && ds.selection.is_empty() {
                return Some("select a layer first".to_string());
            }
            match id.as_str() {
                "edit.undo" if i.session.undo_depth().0 == 0 => Some("nothing to undo".to_string()),
                "edit.redo" if i.session.undo_depth().1 == 0 => Some("nothing to redo".to_string()),
                _ => None,
            }
        })
    }

    pub fn undo(&self) -> Result<bool, BridgeError> {
        self.guarded(|i| {
            let r = i.session.undo();
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    pub fn redo(&self) -> Result<bool, BridgeError> {
        self.guarded(|i| {
            let r = i.session.redo();
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    pub fn state(&self) -> DocState {
        self.guarded_or(
            DocState {
                name: String::new(),
                page: 0,
                page_count: 0,
                selection: Vec::new(),
                tool: "move".into(),
                can_undo: false,
                can_redo: false,
                undo_label: None,
                redo_label: None,
                revision: 0,
                history_id: 0,
                dirty: false,
                zoom: 1.0,
                center_x: 0.0,
                center_y: 0.0,
                editing_text: false,
                vector_editing: false,
                message: Some("internal error".into()),
            },
            |i| {
                i.sync_history();
                let message = i.session.message.take();
                let (undo, redo) = i.session.undo_depth();
                let undo_label = i.session.undo_labels(1).into_iter().next();
                let tool = i.session.tool.tool.id().to_string();
                let (revision, history_id) = (i.revision, i.history_id);
                let Ok(ds) = i.session.ds() else {
                    return DocState {
                        name: String::new(),
                        page: 0,
                        page_count: 0,
                        selection: Vec::new(),
                        tool,
                        can_undo: false,
                        can_redo: false,
                        undo_label: None,
                        redo_label: None,
                        revision,
                        history_id,
                        dirty: false,
                        zoom: 1.0,
                        center_x: 0.0,
                        center_y: 0.0,
                        editing_text: false,
                        vector_editing: false,
                        message,
                    };
                };
                DocState {
                    name: ds.doc.name.clone(),
                    page: ds.page.0,
                    page_count: u32::try_from(ds.doc.pages.len()).unwrap_or(u32::MAX),
                    selection: ds.selection.iter().map(|n| n.0).collect(),
                    tool,
                    can_undo: undo > 0,
                    can_redo: redo > 0,
                    undo_label,
                    redo_label: ds.history.redo.last().map(|h| h.label.clone()),
                    revision: ds.revision.wrapping_add(revision),
                    history_id,
                    dirty: ds.is_dirty(),
                    zoom: ds.view.zoom,
                    center_x: ds.view.cx,
                    center_y: ds.view.cy,
                    editing_text: ds.text_edit.is_some(),
                    vector_editing: ds.vector_edit.is_some(),
                    message,
                }
            },
        )
    }

    pub fn pages(&self) -> Vec<PageInfo> {
        self.guarded_or(Vec::new(), |i| {
            let Ok(ds) = i.session.ds() else { return Vec::new() };
            ds.doc
                .pages
                .iter()
                .map(|p| PageInfo {
                    id: p.0,
                    name: ds.doc.node(*p).map(|n| n.name.clone()).unwrap_or_default(),
                    is_divider: ds.doc.is_divider(*p),
                })
                .collect()
        })
    }

    /// The layer tree of the current page, flattened, z-order top first.
    pub fn layers(&self) -> Vec<LayerRow> {
        self.guarded_or(Vec::new(), |i| {
            let Ok(ds) = i.session.ds() else { return Vec::new() };
            let mut out = Vec::new();
            let mut stack: Vec<(NodeId, Option<u64>, u32)> = Vec::new();
            if let Some(p) = ds.doc.node(ds.page) {
                for c in &p.children {
                    stack.push((*c, None, 0));
                }
            }
            // Children are stored bottom to top: the stack pops the top-most first.
            while let Some((id, parent, depth)) = stack.pop() {
                if out.len() >= 100_000 {
                    break;
                }
                let Some(n) = ds.doc.node(id) else { continue };
                out.push(LayerRow {
                    id: id.0,
                    parent,
                    depth,
                    name: n.name.clone(),
                    kind: kind_name(n.kind.type_name()),
                    visible: n.visible,
                    locked: n.locked,
                    has_children: !n.children.is_empty(),
                    selected: ds.selection.contains(&id),
                });
                if depth < 256 {
                    for c in &n.children {
                        stack.push((*c, Some(id.0), depth + 1));
                    }
                }
            }
            out
        })
    }

    pub fn node_json(&self, id: u64) -> Result<String, BridgeError> {
        self.execute("node.get".into(), json!({"id": id}).to_string())
    }

    pub fn take_ui_requests(&self) -> Vec<UiRequest> {
        self.guarded_or(Vec::new(), |i| {
            std::mem::take(&mut i.session.ui_requests)
                .into_iter()
                .map(|r| UiRequest { kind: r.kind, data_json: r.data.to_string() })
                .collect()
        })
    }

    /// The canvas size in view points. The first call on a fresh document zooms to fit.
    pub fn set_viewport(&self, width: f64, height: f64) {
        if !(width.is_finite() && height.is_finite() && width >= 1.0 && height >= 1.0) {
            return;
        }
        self.guarded_or((), |i| {
            let first = !i.viewport_set;
            i.viewport_set = true;
            if let Ok(ds) = i.session.ds_mut() {
                let changed = (ds.view.vw, ds.view.vh) != (width, height);
                ds.view.vw = width;
                ds.view.vh = height;
                if first {
                    ds.zoom_to_fit();
                }
                if changed || first {
                    ds.revision += 1;
                }
            }
            i.touch();
        });
    }

    pub fn set_view(&self, center_x: f64, center_y: f64, zoom: f64) {
        if !(center_x.is_finite() && center_y.is_finite() && zoom.is_finite()) {
            return;
        }
        self.guarded_or((), |i| {
            if let Ok(ds) = i.session.ds_mut() {
                ds.view.cx = center_x;
                ds.view.cy = center_y;
                ds.view.zoom = zoom.clamp(figcraft_engine::ViewState::MIN_ZOOM, figcraft_engine::ViewState::MAX_ZOOM);
                ds.revision += 1;
            }
            i.touch();
        });
    }

    pub fn pan(&self, dx: f64, dy: f64) {
        self.guarded_or((), |i| {
            if let Ok(ds) = i.session.ds_mut() {
                ds.view.scroll(dx, dy, false);
                ds.revision += 1;
            }
            i.touch();
        });
    }

    pub fn zoom_at(&self, zoom: f64, x: f64, y: f64) {
        if !(zoom.is_finite() && x.is_finite() && y.is_finite()) {
            return;
        }
        self.guarded_or((), |i| {
            if let Ok(ds) = i.session.ds_mut() {
                let anchor = ds.view.screen_to_page(x, y);
                ds.view.set_zoom_at(zoom, anchor);
                ds.revision += 1;
            }
            i.touch();
        });
    }

    /// The whole viewport at `scale` pixels per view point.
    pub fn render(&self, width_px: u32, height_px: u32, scale: f64) -> Result<RenderedImage, BridgeError> {
        check_size(width_px, height_px)?;
        let scale = if scale.is_finite() && scale > 0.0 { scale.min(8.0) } else { 1.0 };
        let (doc, page, view) = self.guarded(|i| {
            let ds = i.session.ds().map_err(|e| fail(e.to_string()))?;
            let v = &ds.view;
            let (ox, oy) = v.origin();
            // Pixel position of the viewport's top-left is (0, 0): the view covers vw x vh points.
            let view = figcraft_render::View { origin: (ox, oy), scale: v.zoom * scale, width: width_px, height: height_px };
            Ok((ds.doc.clone(), ds.page, (view, v.outlines)))
        })?;
        let (view, outlines) = view;
        unwinding(|| {
            let opts = figcraft_render::Options { lod: true, outline_mode: outlines, ..Default::default() };
            let mut pix = figcraft_render::render_view_single(&doc, page, &view, &opts).ok_or_else(|| fail("render failed"))?;
            figcraft_render::to_srgb(&mut pix, doc.color_profile);
            Ok(pix_image(&pix))
        })
    }

    pub fn overlay(&self) -> Overlay {
        let empty = Overlay { selection: Vec::new(), bounds: None, hover: None, marquee: None, caret: None, guides: Vec::new() };
        self.guarded_or(empty, |i| overlay_of(&i.session))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn pointer(
        &self,
        kind: String,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
        cmd: bool,
        ctrl: bool,
        pressure: Option<f64>,
    ) -> Result<(), BridgeError> {
        let kind = match kind.as_str() {
            "down" => PointerKind::Down,
            "move" => PointerKind::Move,
            "up" => PointerKind::Up,
            "hover" => PointerKind::Hover,
            "double" => PointerKind::DoubleClick,
            other => return Err(fail(format!("unknown pointer kind `{other}`"))),
        };
        if !(x.is_finite() && y.is_finite()) {
            return Err(fail("pointer position is not finite"));
        }
        self.guarded(|i| {
            let (px, py, zoom) = {
                let ds = i.session.ds().map_err(|e| fail(e.to_string()))?;
                let (px, py) = ds.view.screen_to_page(x, y);
                (px, py, ds.view.zoom)
            };
            let mut ev = PointerEvent::at(kind, px, py, zoom);
            ev.sx = x;
            ev.sy = y;
            ev.shift = shift;
            ev.alt = alt;
            ev.cmd = cmd;
            ev.ctrl = ctrl;
            ev.pressure = pressure.filter(|p| p.is_finite()).map(|p| p.clamp(0.0, 1.0) as f32);
            let r = i.session.pointer(&ev);
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    pub fn key(&self, name: String, shift: bool, alt: bool, cmd: bool) -> Result<bool, BridgeError> {
        const TEXT_KEYS: [&str; 10] = ["Left", "Right", "Up", "Down", "Backspace", "Delete", "Enter", "Escape", "Tab", "Home"];
        self.guarded(|i| {
            let editing = i.session.ds().is_ok_and(|d| d.text_edit.is_some());
            let r = if editing && (TEXT_KEYS.contains(&name.as_str()) || name == "End") {
                figcraft_engine::textedit::key(&mut i.session, &name, shift, alt, cmd).map(|()| true)
            } else {
                i.session.tool_key(&name, shift, alt, cmd)
            };
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    pub fn insert_text(&self, text: String) -> Result<(), BridgeError> {
        self.guarded(|i| {
            let r = figcraft_engine::textedit::insert(&mut i.session, &text);
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    /// The first page fitted into `edge` x `edge` (aspect kept, so one side is `edge`).
    pub fn thumbnail(&self, edge: u32) -> Result<RenderedImage, BridgeError> {
        let edge = edge.clamp(1, 4096);
        let doc = self.guarded(|i| Ok(i.session.ds().map_err(|e| fail(e.to_string()))?.doc.clone()))?;
        unwinding(|| {
            let page = doc.first_page().ok_or_else(|| fail("the document has no page"))?;
            let b = doc.page_content_bounds(page).filter(|b| b.width() > 0.0 && b.height() > 0.0);
            let (b, w, h, s) = match b {
                Some(b) => {
                    let s = f64::from(edge) / b.width().max(b.height());
                    (b, (b.width() * s).ceil().max(1.0), (b.height() * s).ceil().max(1.0), s)
                }
                None => (figcraft_geom::Rect::new(0.0, 0.0, 1.0, 1.0), f64::from(edge), f64::from(edge), f64::from(edge)),
            };
            let view = figcraft_render::View { origin: (b.x0, b.y0), scale: s, width: w as u32, height: h as u32 };
            let mut pix = figcraft_render::render_view_single(&doc, page, &view, &Default::default()).ok_or_else(|| fail("render failed"))?;
            figcraft_render::to_srgb(&mut pix, doc.color_profile);
            Ok(pix_image(&pix))
        })
    }

    /// Empty `ids`: the selection, else every top-level layer of the page.
    pub fn export_png(&self, ids: Vec<u64>, scale: f64) -> Result<Vec<u8>, BridgeError> {
        self.export(&ids, ExportFormat::Png, scale)
    }

    pub fn export_svg(&self, ids: Vec<u64>) -> Result<Vec<u8>, BridgeError> {
        self.export(&ids, ExportFormat::Svg, 1.0)
    }

    /// Every top-level visible frame of the page, one PDF page each.
    pub fn export_pdf(&self) -> Result<Vec<u8>, BridgeError> {
        let snap = self.snapshot()?;
        unwinding(|| {
            figcraft_engine::cmd::file::frames_pdf(&snap.doc, snap.page, &PrintSettings::default())
                .map(|(b, _)| b)
                .map_err(|e| fail(e.to_string()))
        })
    }

    /// Start a continuous edit (slider drag): everything until `end_interaction` is one undo step.
    pub fn begin_interaction(&self, label: String) -> Result<(), BridgeError> {
        self.guarded(|i| {
            let r = i.session.begin_interaction(&label);
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    pub fn end_interaction(&self) -> Result<(), BridgeError> {
        self.guarded(|i| {
            let r = i.session.commit_interaction();
            i.touch();
            r.map_err(|e| fail(e.to_string()))
        })
    }

    /// A prototype player on a snapshot of the document, starting at `start` (a top-level frame;
    /// default: the selected frame, else the page's first flow, else its first frame).
    pub fn presenter(&self, start: Option<u64>) -> Result<Arc<Presenter>, BridgeError> {
        let (doc, page, selection) = self.guarded(|i| {
            let ds = i.session.ds().map_err(|e| fail(e.to_string()))?;
            Ok((ds.doc.clone(), ds.page, ds.selection.clone()))
        })?;
        unwinding(|| Presenter::start(doc, page, &selection, start))
    }
}

/// `NodeKind::type_name` ("COMPONENT_SET") as contract kinds ("componentSet").
fn kind_name(type_name: &str) -> String {
    let mut out = String::new();
    let mut upper_next = false;
    for c in type_name.chars() {
        if c == '_' {
            upper_next = true;
        } else if upper_next {
            out.push(c.to_ascii_uppercase());
            upper_next = false;
        } else {
            out.push(c.to_ascii_lowercase());
        }
    }
    if out == "booleanOperation" {
        out = "booleanOp".into();
    }
    out
}

fn overlay_of(s: &Session) -> Overlay {
    let empty = Overlay { selection: Vec::new(), bounds: None, hover: None, marquee: None, caret: None, guides: Vec::new() };
    let Ok(ds) = s.ds() else { return empty };
    let view = &ds.view;
    let to_view = |r: figcraft_geom::Rect| {
        let (x0, y0) = view.page_to_screen(r.x0, r.y0);
        let (x1, y1) = view.page_to_screen(r.x1, r.y1);
        figcraft_geom::Rect::new(x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1))
    };
    let mut selection = Vec::new();
    let mut union: Option<figcraft_geom::Rect> = None;
    for id in &ds.selection {
        if let Some(b) = ds.doc.world_bounds(*id) {
            let v = to_view(b);
            union = Some(union.map_or(v, |u| u.union(v)));
            selection.push(rect_of(v));
        }
    }
    let hover = ds.hover.and_then(|h| ds.doc.world_bounds(h)).map(|b| rect_of(to_view(b)));
    let ov = &s.tool.overlay;
    let marquee = ov.marquee.map(|[x0, y0, x1, y1]| rect_of(to_view(figcraft_geom::Rect::new(x0, y0, x1, y1))));
    let guides = ov
        .guides
        .iter()
        .map(|g| {
            let r = to_view(figcraft_geom::Rect::new(g.x0.min(g.x1), g.y0.min(g.y1), g.x0.max(g.x1), g.y0.max(g.y1)));
            let mut r = rect_of(r);
            // A guide is a line: at least one point thick so it can be drawn.
            r.width = r.width.max(1.0);
            r.height = r.height.max(1.0);
            r
        })
        .collect();
    let caret = ds.text_edit.as_ref().and_then(|te| {
        let n = ds.doc.node(te.id)?;
        let (layout, dy) = figcraft_text::layout_node(n)?;
        let (cx, li) = layout.caret(te.caret);
        let (top, h) = layout.lines.get(li).or(layout.lines.last()).map_or((0.0, 14.0), |l| (l.top, l.height));
        let world = ds.doc.world_transform(te.id);
        let a = world * figcraft_geom::Point::new(cx, top + dy);
        let b = world * figcraft_geom::Point::new(cx, top + h + dy);
        let r = to_view(figcraft_geom::Rect::new(a.x.min(b.x), a.y.min(b.y), a.x.max(b.x), a.y.max(b.y)));
        let mut r = rect_of(r);
        r.width = r.width.max(1.5);
        Some(r)
    });
    Overlay { selection, bounds: union.map(rect_of), hover, marquee, caret, guides }
}

/// Every engine command with its menu placement, shortcut and params doc.
#[uniffi::export]
pub fn command_catalog() -> Vec<CommandInfo> {
    catch_unwind(info::command_catalog).unwrap_or_default()
}

/// The menu bar: `catalog::MENU` in order (File ... Help, Tools last).
#[uniffi::export]
pub fn menu_layout() -> Vec<MenuSection> {
    catch_unwind(info::menu_layout).unwrap_or_default()
}

/// The desktop toolbar's groups (parsed from its source; falls back to every tool).
#[uniffi::export]
pub fn tool_groups() -> Vec<ToolGroup> {
    catch_unwind(info::tool_groups).unwrap_or_default()
}

/// Parsed parameters of a command (empty for unknown ids and commands without params).
#[uniffi::export]
pub fn command_params(id: String) -> Vec<ParamField> {
    catch_unwind(|| params_doc::fields_for(&id)).unwrap_or_default()
}

/// `None` = supported on iOS; `Some(reason)` from `ios-excluded-commands.txt`.
#[uniffi::export]
pub fn command_platform_support(id: String) -> Option<String> {
    excluded_reason(&id)
}

#[uniffi::export]
pub fn templates() -> Vec<TemplateInfo> {
    catch_unwind(info::templates).unwrap_or_default()
}

/// Feed a font file to the engine (iOS has no scanned font directory); returns its families.
#[uniffi::export]
pub fn load_font(data: Vec<u8>) -> Vec<String> {
    catch_unwind(AssertUnwindSafe(|| figcraft_text::fontdb::load_font_bytes(data))).unwrap_or_default()
}

#[uniffi::export]
pub fn font_families() -> Vec<String> {
    catch_unwind(figcraft_text::fontdb::family_names).unwrap_or_default()
}

#[uniffi::export]
pub fn engine_version() -> String {
    format!("figcraft-apple {}", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests;
