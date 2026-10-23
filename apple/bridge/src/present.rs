//! Prototype playback for the Swift app: the egui-free core of the desktop player
//! (`crates/ui-egui/src/present.rs`), working on its own copy of the document.
//!
//! The player shows one top-level frame (plus open overlays) on a "screen": the prototype
//! device's screen, else the frame itself. Coordinates in this API are prototype points with the
//! screen's top-left as the origin. Navigation, overlays, scrolling, variables and conditional
//! actions run through the engine's `proto_run` helpers as on the desktop. Transitions are not
//! animated here: `PresentState` reports the last one (kind, direction, duration) so Swift can
//! animate between the images it renders.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};

use figcraft_color::Color;
use figcraft_doc::proto::{Action, Direction, Easing, KeyMods, Overflow, OverlayPosition, PrototypeSettings, ScrollPosition, Transition, Trigger};
use figcraft_doc::{Document, HConstraint, NodeId, NodeKind, VConstraint};
use figcraft_geom::{Affine, Point, Rect as GRect};

use crate::{BridgeError, Rect, RenderedImage, fail, unwinding};

#[derive(Clone, uniffi::Record)]
pub struct FlowInfo {
    pub start: u64,
    pub name: String,
}

#[derive(Clone, uniffi::Record)]
pub struct PresentState {
    pub frame: u64,
    pub frame_name: String,
    pub width: f64,
    pub height: f64,
    pub can_go_back: bool,
    pub overlay_count: u32,
    pub flows: Vec<FlowInfo>,
    /// "instant","dissolve","smartAnimate","moveIn","moveOut","push","slideIn","slideOut"
    pub transition: String,
    /// "left","right","top","bottom" or ""
    pub direction: String,
    pub duration_ms: u32,
    pub open_url: Option<String>,
    pub generation: u64,
}

/// Longest wait a drag may take before it counts as a drag rather than a tap (prototype points).
const DRAG_SLOP: f64 = 6.0;
/// Most pixels the presenter renders.
const MAX_SIDE: u32 = 8192;

#[derive(Clone, Copy, Debug)]
struct Waiting {
    node: NodeId,
    k: usize,
    rect: Option<GRect>,
    root: NodeId,
    due: f64,
}

#[derive(Clone, Debug)]
struct Visit {
    frame: NodeId,
    transition: Transition,
    dur: f64,
    easing: Easing,
}

#[derive(Clone, Debug)]
struct OverlayState {
    id: NodeId,
    position: OverlayPosition,
    close_on_outside: bool,
    background: Option<Color>,
    anchor: Option<GRect>,
    offset: Option<[f64; 2]>,
    /// NaN until the first tick after it opened.
    opened: f64,
}

#[derive(Clone)]
struct Snapshot {
    current: NodeId,
    doc: Document,
    overlays: Vec<OverlayState>,
    history: Vec<Visit>,
    scroll: HashMap<NodeId, (f64, f64)>,
}

/// A "while pressing" state that reverts when the finger lifts.
struct Temp {
    snap: Snapshot,
    transition: Transition,
    dur: f64,
    easing: Easing,
}

/// Page -> screen mapping of one presented layer (scale 1).
#[derive(Clone, Copy, Debug)]
struct Place {
    page_min: (f64, f64),
    origin: (f64, f64),
}

impl Place {
    fn rect(&self, r: GRect) -> GRect {
        let m = |x: f64, y: f64| (self.origin.0 + x - self.page_min.0, self.origin.1 + y - self.page_min.1);
        let (x0, y0) = m(r.x0, r.y0);
        let (x1, y1) = m(r.x1, r.y1);
        GRect::new(x0, y0, x1, y1)
    }
}

struct Layout {
    disp: Arc<Document>,
    screen: GRect,
    place: Place,
    device: bool,
    overlays: Vec<(NodeId, Place, GRect)>,
}

impl Layout {
    /// The active layer (top overlay, else the frame), where it is placed and its clip.
    fn active(&self, current: NodeId) -> (NodeId, Place, GRect) {
        match self.overlays.last() {
            Some((id, pl, _)) => (*id, *pl, self.screen),
            None => (current, self.place, self.screen),
        }
    }
}

struct Core {
    start: NodeId,
    current: NodeId,
    history: Vec<Visit>,
    overlays: Vec<OverlayState>,
    scroll: HashMap<NodeId, (f64, f64)>,
    sections: HashMap<NodeId, NodeId>,
    original: Document,
    /// As designed plus what the prototype changed (variables, variants).
    design: Document,
    /// `design` laid out for the screen.
    doc: Document,
    fit: Option<(f64, f64)>,
    rev: u64,
    display: Option<(u64, Arc<Document>)>,
    /// NaN until the first tick after arriving on the frame.
    arrived: f64,
    clock: f64,
    delays_fired: HashSet<(NodeId, usize)>,
    waiting: Vec<Waiting>,
    press: Option<(f64, f64)>,
    press_moved: (f64, f64),
    dragged: bool,
    pointer: (f64, f64),
    temp: Option<Temp>,
    urls: Vec<String>,
    last: (Transition, f64),
}

// ---------------------------------------------------------------------------------------------
// Pure helpers (ported from the desktop player)

fn page_settings(doc: &Document, id: NodeId) -> PrototypeSettings {
    doc.page_of(id)
        .and_then(|pg| doc.node(pg))
        .and_then(|n| match &n.kind {
            NodeKind::Page { prototype, .. } => Some(prototype.clone()),
            _ => None,
        })
        .unwrap_or_default()
}

fn viewport(doc: &Document, frame: NodeId) -> Option<(f64, f64)> {
    let d = page_settings(doc, frame).device()?;
    let n = doc.node(frame)?;
    Some((n.width.min(d.width), n.height.min(d.height)))
}

fn scroll_range_in(doc: &Document, frame: NodeId, viewport: Option<(f64, f64)>) -> (f64, f64) {
    let Some(n) = doc.node(frame) else { return (0.0, 0.0) };
    if n.overflow == Overflow::None {
        return (0.0, 0.0);
    }
    let (mut x1, mut y1) = (0.0f64, 0.0f64);
    for c in &n.children {
        let Some(cn) = doc.node(*c) else { continue };
        if !cn.visible || cn.scroll_position == ScrollPosition::Fixed {
            continue;
        }
        let b = figcraft_geom::transform_rect_bbox(cn.transform, cn.local_rect());
        x1 = x1.max(b.x1);
        y1 = y1.max(b.y1);
    }
    if let Some(l) = &n.layout {
        x1 += l.padding[1];
        y1 += l.padding[2];
    }
    let (vw, vh) = match viewport {
        Some(v) => {
            x1 = x1.max(n.width);
            y1 = y1.max(n.height);
            v
        }
        None => (n.width, n.height),
    };
    let rx = if matches!(n.overflow, Overflow::Horizontal | Overflow::Both) { (x1 - vw).max(0.0) } else { 0.0 };
    let ry = if matches!(n.overflow, Overflow::Vertical | Overflow::Both) { (y1 - vh).max(0.0) } else { 0.0 };
    (if rx.is_finite() { rx } else { 0.0 }, if ry.is_finite() { ry } else { 0.0 })
}

fn clamp_scroll((x, y): (f64, f64), (rx, ry): (f64, f64)) -> (f64, f64) {
    let c = |v: f64, r: f64| if v.is_finite() && r.is_finite() { v.clamp(0.0, r.max(0.0)) } else { 0.0 };
    (c(x, rx), c(y, ry))
}

fn fit_viewport(doc: &mut Document, frame: NodeId, (w, h): (f64, f64)) {
    let Some(n) = doc.node(frame) else { return };
    let (dw, dh) = (w - n.width, h - n.height);
    if !dw.is_finite() || !dh.is_finite() || (dw == 0.0 && dh == 0.0) {
        return;
    }
    let fixed: Vec<NodeId> =
        n.children.iter().copied().filter(|c| doc.node(*c).is_some_and(|c| c.scroll_position == ScrollPosition::Fixed)).collect();
    for c in fixed {
        if let Some(m) = doc.node_mut(c) {
            let dx = match m.constraints.horizontal {
                HConstraint::Right => dw,
                HConstraint::Center => dw / 2.0,
                _ => 0.0,
            };
            let dy = match m.constraints.vertical {
                VConstraint::Bottom => dh,
                VConstraint::Center => dh / 2.0,
                _ => 0.0,
            };
            m.transform = Affine::translate((dx, dy)) * m.transform;
        }
    }
    if let Some(m) = doc.node_mut(frame) {
        m.width = w;
        m.height = h;
    }
}

fn apply_scroll(doc: &Document, scroll: &HashMap<NodeId, (f64, f64)>) -> Document {
    let mut out = doc.clone();
    let sticky = |pos: f64, s: f64| if pos >= 0.0 && pos - s < 0.0 { -pos } else { -s };
    for (&frame, &(sx, sy)) in scroll {
        if !sx.is_finite() || !sy.is_finite() || (sx == 0.0 && sy == 0.0) {
            continue;
        }
        let Some(n) = doc.node(frame) else { continue };
        for &c in &n.children {
            let Some(cn) = doc.node(c) else { continue };
            let (dx, dy) = match cn.scroll_position {
                ScrollPosition::Fixed => continue,
                ScrollPosition::Scrolls => (-sx, -sy),
                ScrollPosition::Sticky => {
                    let b = figcraft_geom::transform_rect_bbox(cn.transform, cn.local_rect());
                    (sticky(b.x0, sx), sticky(b.y0, sy))
                }
            };
            if let Some(m) = out.node_mut(c) {
                m.transform = Affine::translate((dx, dy)) * m.transform;
            }
        }
    }
    out
}

fn raise_fixed(doc: &mut Document) {
    let fixed = |c: &NodeId| doc.node(*c).is_some_and(|c| c.scroll_position == ScrollPosition::Fixed);
    let moves: Vec<(NodeId, Vec<NodeId>)> = doc
        .nodes()
        .filter(|n| !matches!(n.kind, NodeKind::Page { .. }) && n.children.iter().any(fixed))
        .filter_map(|n| {
            let (top, mut order): (Vec<NodeId>, Vec<NodeId>) = n.children.iter().partition(|c| fixed(c));
            order.extend(top);
            (order != n.children).then_some((n.id, order))
        })
        .collect();
    for (id, order) in moves {
        if let Some(n) = doc.node_mut(id) {
            n.children = order;
        }
    }
}

/// Screen rect of an overlay of `size` over the screen `base`. A manual one sits `offset` from
/// the top-left of `anchor`, the layer that opened it; without an offset, right below it.
fn overlay_rect(pos: OverlayPosition, base: GRect, size: (f64, f64), anchor: Option<GRect>, offset: Option<(f64, f64)>) -> GRect {
    let cx = (base.x0 + base.x1) / 2.0 - size.0 / 2.0;
    let cy = (base.y0 + base.y1) / 2.0 - size.1 / 2.0;
    let (x, y) = match pos {
        OverlayPosition::Center => (cx, cy),
        OverlayPosition::TopLeft => (base.x0, base.y0),
        OverlayPosition::TopCenter => (cx, base.y0),
        OverlayPosition::TopRight => (base.x1 - size.0, base.y0),
        OverlayPosition::BottomLeft => (base.x0, base.y1 - size.1),
        OverlayPosition::BottomCenter => (cx, base.y1 - size.1),
        OverlayPosition::BottomRight => (base.x1 - size.0, base.y1 - size.1),
        OverlayPosition::Manual => match (anchor, offset) {
            (Some(a), Some(o)) => (a.x0 + o.0, a.y0 + o.1),
            (Some(a), None) => (a.x0, a.y1),
            (None, _) => (cx, cy),
        },
    };
    GRect::new(x, y, x + size.0, y + size.1)
}

fn find_trigger(doc: &Document, id: NodeId, want: impl Fn(&Trigger) -> bool) -> Option<usize> {
    doc.node(id)?.interactions.iter().position(|it| want(&it.trigger))
}

fn transition_name(t: Transition) -> &'static str {
    match t {
        Transition::Instant => "instant",
        Transition::Dissolve => "dissolve",
        Transition::SmartAnimate => "smartAnimate",
        Transition::MoveIn { .. } => "moveIn",
        Transition::MoveOut { .. } => "moveOut",
        Transition::Push { .. } => "push",
        Transition::SlideIn { .. } => "slideIn",
        Transition::SlideOut { .. } => "slideOut",
    }
}

fn direction_name(d: Option<Direction>) -> &'static str {
    match d {
        Some(Direction::Left) => "left",
        Some(Direction::Right) => "right",
        Some(Direction::Top) => "top",
        Some(Direction::Bottom) => "bottom",
        None => "",
    }
}

/// `"Shift+K"` -> (`"K"`, shift held).
fn parse_key(spec: &str) -> (String, KeyMods) {
    let mut mods = KeyMods::default();
    let mut parts: Vec<&str> = spec.split('+').collect();
    // A trailing "+" names the plus key itself.
    let key = if spec.ends_with('+') {
        parts.pop();
        parts.pop();
        "+".to_string()
    } else {
        parts.pop().unwrap_or("").to_string()
    };
    for m in parts {
        match m.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => mods.ctrl = true,
            "alt" | "option" => mods.alt = true,
            "shift" => mods.shift = true,
            "cmd" | "command" | "meta" => mods.cmd = true,
            _ => {}
        }
    }
    (key, mods)
}

// ---------------------------------------------------------------------------------------------
// The player

impl Core {
    fn new(doc: Document, start: NodeId) -> Self {
        let mut c = Self {
            start,
            current: start,
            history: Vec::new(),
            overlays: Vec::new(),
            scroll: HashMap::new(),
            sections: HashMap::new(),
            original: doc.clone(),
            design: doc.clone(),
            doc,
            fit: None,
            rev: 1,
            display: None,
            arrived: f64::NAN,
            clock: 0.0,
            delays_fired: HashSet::new(),
            waiting: Vec::new(),
            press: None,
            press_moved: (0.0, 0.0),
            dragged: false,
            pointer: (0.0, 0.0),
            temp: None,
            urls: Vec::new(),
            last: (Transition::Instant, 0.0),
        };
        c.relayout();
        c.arrive();
        c
    }

    fn relayout(&mut self) {
        let mut d = self.design.clone();
        if let Some(size) = self.fit {
            figcraft_engine::cmd::proto::respond(&mut d, self.current, size);
        }
        figcraft_engine::proto_run::play_interactions(&mut d);
        raise_fixed(&mut d);
        self.doc = d;
        self.rev += 1;
    }

    fn respond_to(&mut self, size: Option<(f64, f64)>) {
        if self.fit != size {
            self.fit = size;
            self.relayout();
        }
    }

    fn display(&mut self) -> Arc<Document> {
        if let Some((r, d)) = &self.display
            && *r == self.rev
        {
            return d.clone();
        }
        let mut d = apply_scroll(&self.doc, &self.scroll);
        if let Some(vp) = viewport(&self.doc, self.current) {
            fit_viewport(&mut d, self.current, vp);
        }
        let d = Arc::new(d);
        self.display = Some((self.rev, d.clone()));
        d
    }

    fn range(&self, frame: NodeId) -> (f64, f64) {
        let vp = if frame == self.current { viewport(&self.doc, frame) } else { None };
        scroll_range_in(&self.doc, frame, vp)
    }

    fn arrive(&mut self) {
        figcraft_engine::proto_run::remember_sections(&self.doc, self.current, &mut self.sections);
        self.arrived = f64::NAN;
        self.delays_fired.clear();
        self.waiting.clear();
        self.rev += 1;
    }

    fn layout(&mut self) -> Option<Layout> {
        if !self.doc.contains(self.current) {
            return None;
        }
        let settings = page_settings(&self.doc, self.current);
        let device = settings.device();
        self.respond_to(if settings.responsive { device.map(|d| (d.width, d.height)) } else { None });
        let disp = self.display();
        let fb = disp.world_bounds(self.current)?;
        let (sw, sh) = device.map_or((fb.width(), fb.height()), |d| (d.width, d.height));
        let screen = GRect::new(0.0, 0.0, sw, sh);
        let place = Place { page_min: (fb.x0, fb.y0), origin: ((sw - fb.width()) / 2.0, (sh - fb.height()) / 2.0) };
        let overlays = self
            .overlays
            .iter()
            .filter_map(|o| {
                let ob = disp.world_bounds(o.id)?;
                let r = overlay_rect(o.position, screen, (ob.width(), ob.height()), o.anchor, o.offset.map(|[x, y]| (x, y)));
                Some((o.id, Place { page_min: (ob.x0, ob.y0), origin: (r.x0, r.y0) }, r))
            })
            .collect();
        Some(Layout { disp, screen, place, device: device.is_some(), overlays })
    }

    fn hotspot_rects(&self, l: &Layout, root: NodeId, place: &Place, clip: GRect) -> Vec<(NodeId, GRect)> {
        figcraft_engine::proto_run::hotspots(&l.disp, root)
            .into_iter()
            .map(|(id, b)| (id, place.rect(b).intersect(clip)))
            .filter(|(_, r)| r.width() > 0.0 && r.height() > 0.0)
            .collect()
    }

    fn close_overlay(&mut self) -> bool {
        self.overlays.pop().is_some()
    }

    fn go(&mut self, frame: NodeId, transition: Transition, dur: f64, easing: Easing, remember: bool, preserve: bool) {
        self.last = (transition, dur);
        if remember {
            self.history.push(Visit { frame: self.current, transition, dur, easing });
        }
        let kept = self.scroll.get(&self.current).copied().filter(|_| preserve);
        self.overlays.clear();
        self.scroll.clear();
        self.temp = None;
        self.current = frame;
        self.relayout();
        if let Some(s) = kept {
            let to = clamp_scroll(s, self.range(frame));
            self.scroll.insert(frame, to);
        }
        self.arrive();
    }

    fn restart(&mut self, start: Option<NodeId>) {
        if let Some(s) = start.filter(|s| self.original.contains(*s)) {
            self.start = s;
        }
        self.current = self.start;
        self.sections.clear();
        self.history.clear();
        self.overlays.clear();
        self.scroll.clear();
        self.temp = None;
        self.press = None;
        self.design = self.original.clone();
        self.fit = None;
        self.relayout();
        self.arrive();
    }

    fn back(&mut self) -> bool {
        if self.close_overlay() {
            self.rev += 1;
            return true;
        }
        match self.history.pop() {
            Some(v) => {
                self.go(v.frame, v.transition.reversed(), v.dur, v.easing, false, false);
                true
            }
            None => false,
        }
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            current: self.current,
            doc: self.design.clone(),
            overlays: self.overlays.clone(),
            history: self.history.clone(),
            scroll: self.scroll.clone(),
        }
    }

    fn revert(&mut self) -> bool {
        let Some(t) = self.temp.take() else { return false };
        self.last = (t.transition.reversed(), t.dur);
        let _ = t.easing;
        self.current = t.snap.current;
        self.design = t.snap.doc;
        self.relayout();
        self.overlays = t.snap.overlays;
        self.history = t.snap.history;
        self.scroll = t.snap.scroll;
        self.rev += 1;
        true
    }

    /// Mouse down/up on `node`: run now, or after the interaction's delay while `root` still shows.
    fn gesture(&mut self, node: NodeId, k: usize, rect: Option<GRect>, root: NodeId) -> bool {
        let delay = self.doc.node(node).and_then(|n| n.interactions.get(k)).map_or(0.0, |it| it.delay_secs());
        if delay <= 0.0 {
            return self.fire(node, k, rect);
        }
        if !self.waiting.iter().any(|w| (w.node, w.k) == (node, k)) {
            self.waiting.push(Waiting { node, k, rect, root, due: self.clock + delay });
        }
        false
    }

    fn fire_waiting(&mut self, root: NodeId) -> bool {
        let now = self.clock;
        let (due, later): (Vec<Waiting>, Vec<Waiting>) = std::mem::take(&mut self.waiting).into_iter().partition(|w| w.due <= now);
        self.waiting = later;
        self.waiting.retain(|w| w.root == root);
        let mut did = false;
        for w in due.into_iter().filter(|w| w.root == root) {
            did = did || self.fire(w.node, w.k, w.rect);
        }
        did
    }

    fn fire(&mut self, node: NodeId, k: usize, rect: Option<GRect>) -> bool {
        let Some(it) = self.doc.node(node).and_then(|n| n.interactions.get(k)).cloned() else { return false };
        let dur = it.easing.seconds(it.duration_ms);
        let snap = (it.trigger == Trigger::OnPress && self.temp.is_none()).then(|| self.snapshot());
        let mut did = false;
        for a in &it.actions {
            did |= self.perform_at(a, node, it.transition, dur, it.easing, rect, 0);
        }
        if did && let Some(snap) = snap {
            self.temp = Some(Temp { snap, transition: it.transition, dur, easing: it.easing });
        }
        did
    }

    #[allow(clippy::too_many_arguments)]
    fn perform_at(&mut self, a: &Action, node: NodeId, tr: Transition, dur: f64, easing: Easing, rect: Option<GRect>, depth: usize) -> bool {
        let doc = &self.doc;
        match a {
            Action::Navigate { dest, preserve_scroll } => {
                let Some(top) = figcraft_engine::proto_run::navigate_target(doc, *dest, &self.sections) else { return false };
                if !doc.contains(top) || (top == self.current && self.overlays.is_empty()) {
                    return false;
                }
                self.go(top, tr, dur, easing, true, *preserve_scroll);
                true
            }
            Action::Back => self.back(),
            Action::ScrollTo { dest, offset } => {
                let moves = self.scroll_to_layer(*dest, *offset);
                if moves.is_empty() {
                    return false;
                }
                for (f, to) in moves {
                    self.scroll.insert(f, to);
                }
                self.rev += 1;
                true
            }
            Action::OpenOverlay { dest, position, close_on_outside, background, offset } => {
                if !doc.contains(*dest) {
                    return false;
                }
                let dest = *dest;
                self.delays_fired.retain(|(id, _)| !self.doc.is_ancestor(dest, *id));
                self.last = (tr, dur);
                self.overlays.push(OverlayState {
                    id: dest,
                    position: *position,
                    close_on_outside: *close_on_outside,
                    background: *background,
                    anchor: rect,
                    offset: *offset,
                    opened: f64::NAN,
                });
                self.rev += 1;
                true
            }
            Action::SwapOverlay { dest } => {
                if !doc.contains(*dest) {
                    return false;
                }
                let dest = *dest;
                self.delays_fired.retain(|(id, _)| !self.doc.is_ancestor(dest, *id));
                self.last = (tr, dur);
                match self.overlays.last_mut() {
                    Some(o) => {
                        o.id = dest;
                        o.opened = f64::NAN;
                    }
                    None => self.overlays.push(OverlayState {
                        id: dest,
                        position: OverlayPosition::Center,
                        close_on_outside: true,
                        background: None,
                        anchor: rect,
                        offset: None,
                        opened: f64::NAN,
                    }),
                }
                self.rev += 1;
                true
            }
            Action::CloseOverlay => {
                let did = self.close_overlay();
                if did {
                    self.rev += 1;
                }
                did
            }
            Action::OpenUrl { url } => {
                // Only web links open: the action can fire from a delay, with no click implied.
                if figcraft_engine::doc_urls::openable(url) {
                    self.urls.push(url.clone());
                }
                true
            }
            Action::ChangeTo { dest } => {
                let Some(inst) = figcraft_engine::proto_run::change_to_target(doc, node, *dest) else { return false };
                if !doc.contains(*dest) {
                    return false;
                }
                self.last = (tr, dur);
                let d = &mut self.design;
                if let Some(n) = d.node_mut(inst)
                    && let NodeKind::Instance { component, .. } = &mut n.kind
                {
                    *component = *dest;
                }
                figcraft_engine::components::sync_instance(d, inst);
                self.relayout();
                true
            }
            Action::SetVariable { variable, value, expr } => {
                let set = figcraft_engine::proto_run::set_variable(&mut self.design, node, variable, value, expr.as_ref());
                if set {
                    self.relayout();
                }
                set
            }
            Action::SetVariableMode { collection, mode } => {
                let set = figcraft_engine::proto_run::set_mode(&mut self.design, self.current, collection, mode);
                if set {
                    self.relayout();
                }
                set
            }
            Action::Conditional { blocks } => {
                if depth >= figcraft_doc::proto::MAX_ACTION_DEPTH {
                    return false;
                }
                // Evaluated now: earlier actions of the interaction may have changed variables.
                let chosen = figcraft_engine::proto_run::branch(doc, node, blocks);
                let mut did = false;
                for inner in chosen {
                    did |= self.perform_at(&inner, node, tr, dur, easing, rect, depth + 1);
                }
                did
            }
        }
    }

    /// "Scroll to" `dest`: each scrolling frame around it (innermost first) and where it ends up.
    fn scroll_to_layer(&self, dest: NodeId, offset: [f64; 2]) -> Vec<(NodeId, (f64, f64))> {
        let doc = &self.doc;
        let mut out = Vec::new();
        let mut target = dest;
        let mut off = offset.map(|v| if v.is_finite() { v } else { 0.0 });
        for f in doc.ancestors(dest) {
            let (rx, ry) = self.range(f);
            let Some(tn) = doc.node(target) else { break };
            if rx <= 0.0 && ry <= 0.0 {
                continue;
            }
            let rel = doc.world_transform(f).inverse() * doc.world_transform(target);
            let b = figcraft_geom::transform_rect_bbox(rel, tn.local_rect());
            let from = self.scroll.get(&f).copied().unwrap_or((0.0, 0.0));
            let to = clamp_scroll((if rx > 0.0 { b.x0 - off[0] } else { from.0 }, if ry > 0.0 { b.y0 - off[1] } else { from.1 }), (rx, ry));
            out.push((f, to));
            target = f;
            off = [0.0, 0.0];
        }
        out
    }

    /// Scrolling frames under `q` (innermost first).
    fn scrollers_at(&self, l: &Layout, root: NodeId, place: &Place, q: Point) -> Vec<NodeId> {
        let disp = &l.disp;
        let mut out: Vec<NodeId> = disp
            .subtree(root)
            .into_iter()
            .filter(|f| disp.node(*f).is_some_and(|n| n.visible && n.overflow != Overflow::None))
            .filter(|f| disp.world_bounds(*f).is_some_and(|b| place.rect(b).contains(q)))
            .filter(|f| self.range(*f) != (0.0, 0.0))
            .collect();
        out.reverse();
        out
    }

    /// Hit layers under `q` with their rects, top-most first.
    fn hits(&self, l: &Layout, root: NodeId, place: &Place, clip: GRect, q: Point) -> Vec<(NodeId, GRect)> {
        self.hotspot_rects(l, root, place, clip).into_iter().rev().filter(|(_, r)| r.contains(q)).collect()
    }

    fn pick(&self, l: &Layout, hits: &[(NodeId, GRect)], want: impl Fn(&Trigger) -> bool) -> Option<(NodeId, usize, GRect)> {
        hits.iter().find_map(|(id, r)| find_trigger(&l.disp, *id, &want).map(|k| (*id, k, *r)))
    }

    fn tap(&mut self, x: f64, y: f64) -> bool {
        self.pointer = (x, y);
        let Some(l) = self.layout() else { return false };
        let q = Point::new(x, y);
        let (root, place, clip) = l.active(self.current);
        if let (Some((_, _, orect)), Some(o)) = (l.overlays.last(), self.overlays.last())
            && !orect.contains(q)
        {
            if o.close_on_outside {
                self.overlays.pop();
                self.rev += 1;
                return true;
            }
            return false;
        }
        let hits = self.hits(&l, root, &place, clip, q);
        match self.pick(&l, &hits, |t| *t == Trigger::OnClick) {
            Some((id, k, r)) => self.fire(id, k, Some(r)),
            None => false,
        }
    }

    fn press(&mut self, x: f64, y: f64, down: bool) -> bool {
        self.pointer = (x, y);
        let Some(l) = self.layout() else { return false };
        let q = Point::new(x, y);
        let (root, place, clip) = l.active(self.current);
        if down {
            self.press = Some((x, y));
            self.press_moved = (0.0, 0.0);
            self.dragged = false;
            let hits = self.hits(&l, root, &place, clip, q);
            if let Some((id, k, r)) = self.pick(&l, &hits, |t| *t == Trigger::MouseDown)
                && self.gesture(id, k, Some(r), root)
            {
                return true;
            }
            if let Some((id, k, r)) = self.pick(&l, &hits, |t| *t == Trigger::OnPress)
                && self.fire(id, k, Some(r))
            {
                return true;
            }
            false
        } else {
            self.press = None;
            self.dragged = false;
            let mut did = self.revert();
            if self.doc.contains(self.current) {
                let Some(l) = self.layout() else { return did };
                let (root, place, clip) = l.active(self.current);
                let hits = self.hits(&l, root, &place, clip, q);
                if let Some((id, k, r)) = self.pick(&l, &hits, |t| *t == Trigger::MouseUp) {
                    did |= self.gesture(id, k, Some(r), root);
                }
            }
            did
        }
    }

    fn drag(&mut self, dx: f64, dy: f64) -> bool {
        if !dx.is_finite() || !dy.is_finite() {
            return false;
        }
        let Some(l) = self.layout() else { return false };
        let (root, place, clip) = l.active(self.current);
        let start = self.press.unwrap_or(self.pointer);
        self.press_moved = (self.press_moved.0 + dx, self.press_moved.1 + dy);
        let (mx, my) = self.press_moved;
        if !self.dragged && self.press.is_some() && mx.hypot(my) > DRAG_SLOP {
            self.dragged = true;
            let at_start = self.hits(&l, root, &place, clip, Point::new(start.0, start.1));
            let drags = |id: NodeId| {
                self.doc.node(id)?.interactions.iter().position(|it| it.trigger == Trigger::OnDrag && it.transition.accepts_drag(mx as f32, my as f32))
            };
            if let Some((id, k, r)) = at_start.iter().find_map(|(id, r)| drags(*id).map(|k| (*id, k, *r)))
                && self.fire(id, k, Some(r))
            {
                self.press = None;
                return true;
            }
        }
        // Scroll the frame under where the drag began: content follows the finger.
        let horizontal = dx.abs() >= dy.abs();
        let scrolls = self.scrollers_at(&l, root, &place, Point::new(start.0, start.1));
        let on_axis = |range: (f64, f64)| if horizontal { range.0 > 0.0 } else { range.1 > 0.0 };
        let Some(target) = scrolls.iter().copied().find(|f| on_axis(self.range(*f))).or_else(|| scrolls.first().copied()) else {
            return false;
        };
        let cur = self.scroll.get(&target).copied().unwrap_or((0.0, 0.0));
        let next = clamp_scroll((cur.0 - dx, cur.1 - dy), self.range(target));
        if (next.0 - cur.0).abs() < 1e-9 && (next.1 - cur.1).abs() < 1e-9 {
            return false;
        }
        self.scroll.insert(target, next);
        self.rev += 1;
        true
    }

    fn key(&mut self, spec: &str) -> bool {
        let (name, mods) = parse_key(spec);
        if name.is_empty() {
            return false;
        }
        let Some(l) = self.layout() else { return false };
        let (root, _, _) = l.active(self.current);
        let found =
            l.disp.subtree(root).into_iter().find_map(|id| find_trigger(&l.disp, id, |t| t.fires_on_key(&name, mods)).map(|k| (id, k)));
        if let Some((id, k)) = found {
            return self.fire(id, k, None);
        }
        // Arrows (and Space or N forward) step through the page's top-level frames.
        let none = !(mods.ctrl || mods.alt || mods.shift || mods.cmd);
        let forward = match name.as_str() {
            "ArrowRight" => Some(true),
            "Space" | "N" | "n" | " " if none => Some(true),
            "ArrowLeft" => Some(false),
            _ => None,
        };
        if let Some(forward) = forward
            && self.overlays.is_empty()
        {
            let frames = self.doc.top_frames(self.doc.page_of(self.current).unwrap_or(self.current));
            if let Some(i) = frames.iter().position(|f| *f == self.current) {
                let next = if forward { frames.get(i + 1) } else { i.checked_sub(1).and_then(|j| frames.get(j)) };
                if let Some(n) = next.copied() {
                    self.go(n, Transition::Instant, 0.0, Easing::Linear, true, false);
                    return true;
                }
            }
        }
        false
    }

    /// The soonest unfired "after delay" interaction under `root` and the seconds until it is due.
    fn next_delay(&self, doc: &Document, root: NodeId, now: f64) -> Option<((NodeId, usize), f64)> {
        let since = self.overlays.last().filter(|o| o.id == root).map_or(self.arrived, |o| o.opened);
        let mut next: Option<((NodeId, usize), f64)> = None;
        for id in doc.subtree(root) {
            let Some(n) = doc.node(id) else { continue };
            for (k, it) in n.interactions.iter().enumerate() {
                if let Trigger::AfterDelay { ms } = it.trigger
                    && !self.delays_fired.contains(&(id, k))
                {
                    let due = since + f64::from(ms) / 1000.0 - now;
                    if next.is_none_or(|(_, d)| due < d) {
                        next = Some(((id, k), due));
                    }
                }
            }
        }
        next
    }

    fn tick(&mut self, now_ms: f64) -> bool {
        if !now_ms.is_finite() {
            return false;
        }
        let now = now_ms / 1000.0;
        self.clock = now;
        if self.arrived.is_nan() {
            self.arrived = now;
        }
        for o in &mut self.overlays {
            if o.opened.is_nan() {
                o.opened = now;
            }
        }
        let rev = self.rev;
        let Some(l) = self.layout() else { return false };
        let (root, _, _) = l.active(self.current);
        let mut did = self.fire_waiting(root);
        if !did && let Some(((id, k), due)) = self.next_delay(&l.disp, root, now) && due <= 0.0 {
            self.delays_fired.insert((id, k));
            did = self.fire(id, k, None);
        }
        did || self.rev != rev
    }

    fn state(&mut self) -> PresentState {
        let layout = self.layout();
        let (width, height) = layout.as_ref().map_or_else(
            || self.doc.node(self.current).map_or((0.0, 0.0), |n| (n.width, n.height)),
            |l| (l.screen.width(), l.screen.height()),
        );
        let flows = self
            .doc
            .page_of(self.current)
            .and_then(|p| self.doc.node(p))
            .map(|p| match &p.kind {
                NodeKind::Page { flows, .. } => flows.iter().map(|f| FlowInfo { start: f.start.0, name: f.name.clone() }).collect(),
                _ => Vec::new(),
            })
            .unwrap_or_default();
        let open_url = if self.urls.is_empty() { None } else { Some(self.urls.remove(0)) };
        PresentState {
            frame: self.current.0,
            frame_name: self.doc.node(self.current).map(|n| n.name.clone()).unwrap_or_default(),
            width,
            height,
            can_go_back: !self.history.is_empty() || !self.overlays.is_empty(),
            overlay_count: u32::try_from(self.overlays.len()).unwrap_or(u32::MAX),
            flows,
            transition: transition_name(self.last.0).into(),
            direction: direction_name(self.last.0.direction()).into(),
            duration_ms: (self.last.1 * 1000.0).round().clamp(0.0, 600_000.0) as u32,
            open_url,
            generation: self.rev,
        }
    }

    fn hotspots(&mut self) -> Vec<Rect> {
        let Some(l) = self.layout() else { return Vec::new() };
        let (root, place, clip) = l.active(self.current);
        self.hotspot_rects(&l, root, &place, clip)
            .into_iter()
            .map(|(_, r)| Rect { x: r.x0, y: r.y0, width: r.width(), height: r.height() })
            .collect()
    }

    /// What `render` needs, so the drawing runs outside the lock.
    fn plan(&mut self) -> Option<Plan> {
        let l = self.layout()?;
        let bg = page_settings(&self.doc, self.current).background;
        let overlays = l
            .overlays
            .iter()
            .map(|(id, place, rect)| PlanOverlay {
                id: *id,
                place: *place,
                rect: *rect,
                background: self.overlays.iter().find(|o| o.id == *id).and_then(|o| o.background),
            })
            .collect();
        Some(Plan {
            disp: l.disp.clone(),
            current: self.current,
            place: l.place,
            screen: l.screen,
            device: l.device,
            bg,
            overlays,
            seconds: if self.arrived.is_nan() { 0.0 } else { (self.clock - self.arrived).max(0.0) },
        })
    }
}

struct PlanOverlay {
    id: NodeId,
    place: Place,
    rect: GRect,
    background: Option<Color>,
}

struct Plan {
    disp: Arc<Document>,
    current: NodeId,
    place: Place,
    screen: GRect,
    device: bool,
    bg: Color,
    overlays: Vec<PlanOverlay>,
    seconds: f64,
}

impl Plan {
    fn draw(&self, w: u32, h: u32) -> Result<RenderedImage, BridgeError> {
        use tiny_skia::{FillRule, Mask, Paint, PathBuilder, PixmapPaint, Transform};
        let (sw, sh) = (self.screen.width().max(1.0), self.screen.height().max(1.0));
        let s = (f64::from(w) / sw).min(f64::from(h) / sh);
        let s = if s.is_finite() && s > 0.0 { s.clamp(1e-3, 8.0) } else { 1.0 };
        let (ox, oy) = ((f64::from(w) - sw * s) / 2.0, (f64::from(h) - sh * s) / 2.0);
        let mut canvas = figcraft_render::Pixmap::new(w, h).ok_or_else(|| fail("cannot allocate the image"))?;
        canvas.fill(figcraft_render::paint::ts_color(self.bg));
        let screen_rect = tiny_skia::Rect::from_xywh(ox as f32, oy as f32, (sw * s) as f32, (sh * s) as f32);
        // On a device the screen clips what is drawn; without one shadows may spill around the frame.
        let mask = if self.device {
            screen_rect.and_then(|r| {
                let path = PathBuilder::from_rect(r);
                let mut m = Mask::new(w, h)?;
                m.fill_path(&path, FillRule::Winding, true, Transform::identity());
                Some(m)
            })
        } else {
            None
        };
        let doc = &*self.disp;
        let draw_node = |canvas: &mut figcraft_render::Pixmap, id: NodeId, place: &Place| {
            let Some(b) = figcraft_render::export_bounds(doc, id) else { return };
            let Some(mut pix) = figcraft_render::render_node_at(doc, id, s, self.seconds) else { return };
            figcraft_render::to_srgb(&mut pix, doc.color_profile);
            let x = ox + (place.origin.0 + b.x0 - place.page_min.0) * s;
            let y = oy + (place.origin.1 + b.y0 - place.page_min.1) * s;
            canvas.draw_pixmap(x.round() as i32, y.round() as i32, pix.as_ref(), &PixmapPaint::default(), Transform::identity(), mask.as_ref());
        };
        draw_node(&mut canvas, self.current, &self.place);
        for o in &self.overlays {
            if let (Some(bg), Some(r)) = (o.background, screen_rect) {
                let mut paint = Paint::default();
                paint.set_color(figcraft_render::paint::ts_color(bg));
                canvas.fill_rect(r, &paint, Transform::identity(), mask.as_ref());
            }
            draw_node(&mut canvas, o.id, &o.place);
            let _ = o.rect;
        }
        Ok(crate::pix_image(&canvas))
    }
}

#[derive(uniffi::Object)]
pub struct Presenter {
    core: Mutex<Core>,
}

impl Presenter {
    pub(crate) fn start(doc: Arc<Document>, page: NodeId, selection: &[NodeId], start: Option<u64>) -> Result<Arc<Self>, BridgeError> {
        let top = |id: NodeId| doc.top_level_frame(id).filter(|f| doc.contains(*f));
        let flow_start = doc.node(page).and_then(|p| match &p.kind {
            NodeKind::Page { flows, .. } => flows.first().map(|f| f.start),
            _ => None,
        });
        let frame = start
            .map(NodeId)
            .and_then(top)
            .or_else(|| selection.iter().find_map(|s| top(*s)))
            .or_else(|| flow_start.and_then(top))
            .or_else(|| doc.top_frames(page).first().copied())
            .ok_or_else(|| fail("there is no frame to present"))?;
        Ok(Arc::new(Self { core: Mutex::new(Core::new(Document::clone(&doc), frame)) }))
    }

    fn with<T>(&self, fallback: T, f: impl FnOnce(&mut Core) -> T) -> T {
        let mut g = self.core.lock().unwrap_or_else(PoisonError::into_inner);
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&mut g))).unwrap_or(fallback)
    }
}

#[uniffi::export]
impl Presenter {
    pub fn state(&self) -> PresentState {
        self.with(
            PresentState {
                frame: 0,
                frame_name: String::new(),
                width: 0.0,
                height: 0.0,
                can_go_back: false,
                overlay_count: 0,
                flows: Vec::new(),
                transition: "instant".into(),
                direction: String::new(),
                duration_ms: 0,
                open_url: None,
                generation: 0,
            },
            Core::state,
        )
    }

    /// The current frame with its overlays and scroll offsets, fitted (aspect kept, centred) into
    /// `width_px` x `height_px`. RGBA8 premultiplied.
    pub fn render(&self, width_px: u32, height_px: u32) -> Result<RenderedImage, BridgeError> {
        if width_px == 0 || height_px == 0 || width_px > MAX_SIDE || height_px > MAX_SIDE {
            return Err(fail(format!("unsupported image size {width_px}x{height_px}")));
        }
        let plan = self.with(None, Core::plan).ok_or_else(|| fail("nothing to present"))?;
        unwinding(|| plan.draw(width_px, height_px))
    }

    /// A tap (onClick, or closing an overlay by tapping outside it); true = something reacted.
    pub fn tap(&self, x: f64, y: f64) -> bool {
        self.with(false, |c| c.tap(x, y))
    }

    /// Finger down or up: onPress (reverted on up) and mouseDown / mouseUp triggers.
    pub fn press(&self, x: f64, y: f64, down: bool) -> bool {
        self.with(false, |c| c.press(x, y, down))
    }

    /// An incremental drag of (`dx`, `dy`) prototype points since the last call: the onDrag
    /// trigger where the press began, else it scrolls the frame under it.
    pub fn drag(&self, dx: f64, dy: f64) -> bool {
        self.with(false, |c| c.drag(dx, dy))
    }

    /// keyPress triggers ("Space", "K", "Shift+K", "ArrowLeft"); arrows step through the frames.
    pub fn key(&self, key: String) -> bool {
        self.with(false, |c| c.key(&key))
    }

    /// Timers: `now_ms` is a monotonic clock in milliseconds. True = the picture changed.
    pub fn tick(&self, now_ms: f64) -> bool {
        self.with(false, |c| c.tick(now_ms))
    }

    pub fn back(&self) -> bool {
        self.with(false, Core::back)
    }

    pub fn restart(&self, start: Option<u64>) {
        self.with((), |c| c.restart(start.map(NodeId)));
    }

    /// The layers that react, for hint flashes (prototype points).
    pub fn hotspots(&self) -> Vec<Rect> {
        self.with(Vec::new(), Core::hotspots)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::DocumentHandle;
    use serde_json::{Value, json};

    fn run(h: &DocumentHandle, id: &str, p: Value) -> Value {
        serde_json::from_str(&h.execute(id.into(), p.to_string()).unwrap()).unwrap()
    }

    /// Two 200x300 frames side by side; frame A holds a button wired to navigate to B.
    fn two_frames() -> (Arc<DocumentHandle>, u64, u64, u64) {
        let h = DocumentHandle::new_document("Proto".into(), false);
        let a = run(&h, "node.create", json!({"type": "frame", "x": 0, "y": 0, "width": 200, "height": 300, "name": "A"}))["id"].as_u64().unwrap();
        let b = run(&h, "node.create", json!({"type": "frame", "x": 400, "y": 0, "width": 200, "height": 300, "name": "B"}))["id"].as_u64().unwrap();
        let btn = run(&h, "node.create", json!({"type": "rectangle", "parent": a, "x": 20, "y": 20, "width": 100, "height": 40, "name": "Button"}))["id"].as_u64().unwrap();
        run(&h, "proto.interaction.add", json!({"id": btn, "dest": b}));
        // A back button on B.
        let back = run(&h, "node.create", json!({"type": "rectangle", "parent": b, "x": 20, "y": 20, "width": 100, "height": 40, "name": "Back"}))["id"].as_u64().unwrap();
        run(&h, "proto.interaction.add", json!({"id": back, "action": {"type": "back"}}));
        (h, a, b, btn)
    }

    fn centre(r: &Rect) -> (f64, f64) {
        (r.x + r.width / 2.0, r.y + r.height / 2.0)
    }

    #[test]
    fn tap_navigates_and_back_returns() {
        let (h, a, b, _) = two_frames();
        let p = h.presenter(Some(a)).unwrap();
        let s = p.state();
        assert_eq!((s.frame, s.frame_name.as_str(), s.width, s.height), (a, "A", 200.0, 300.0));
        assert!(!s.can_go_back);
        let spots = p.hotspots();
        assert_eq!(spots.len(), 1, "{}", spots.len());
        let g0 = s.generation;
        // Tapping nothing reacts to nothing.
        assert!(!p.tap(190.0, 290.0));
        let (x, y) = centre(&spots[0]);
        assert!(p.tap(x, y));
        let s = p.state();
        assert_eq!(s.frame, b);
        assert!(s.can_go_back);
        assert!(s.generation > g0);
        assert_eq!(s.transition, "instant");
        // The back button on B (its hotspot is on B now).
        let spots = p.hotspots();
        assert_eq!(spots.len(), 1);
        let (x, y) = centre(&spots[0]);
        assert!(p.tap(x, y));
        assert_eq!(p.state().frame, a);
        assert!(!p.back());
        // Navigate again, then Back through the API.
        let (x, y) = centre(&p.hotspots()[0]);
        assert!(p.tap(x, y));
        assert!(p.back());
        assert_eq!(p.state().frame, a);
        // Restart returns to the start frame.
        let (x, y) = centre(&p.hotspots()[0]);
        assert!(p.tap(x, y));
        p.restart(None);
        let s = p.state();
        assert_eq!(s.frame, a);
        assert!(!s.can_go_back);
    }

    #[test]
    fn transition_is_reported() {
        let (h, a, b, btn) = two_frames();
        run(&h, "proto.interaction.clear", json!({"ids": [btn]}));
        run(&h, "proto.interaction.add", json!({"id": btn, "action": {"type": "navigate", "dest": b}, "transition": {"type": "push", "direction": "left"}, "durationMs": 450, "easing": "linear"}));
        let p = h.presenter(Some(a)).unwrap();
        let (x, y) = centre(&p.hotspots()[0]);
        assert!(p.tap(x, y));
        let s = p.state();
        assert_eq!((s.transition.as_str(), s.direction.as_str(), s.duration_ms), ("push", "left", 450));
        assert!(p.back());
        let s = p.state();
        assert_eq!((s.transition.as_str(), s.direction.as_str()), ("push", "right"));
    }

    #[test]
    fn render_fills_the_requested_size_and_the_prototype_does_not_touch_the_file() {
        let (h, a, _, _) = two_frames();
        let before = h.state().history_id;
        let p = h.presenter(Some(a)).unwrap();
        let img = p.render(400, 600).unwrap();
        assert_eq!((img.width, img.height, img.rgba.len()), (400, 600, 400 * 600 * 4));
        assert!(img.rgba.iter().any(|b| *b != 0));
        let (x, y) = centre(&p.hotspots()[0]);
        assert!(p.tap(x, y));
        assert!(p.render(300, 300).is_ok());
        assert!(p.render(0, 10).is_err());
        assert_eq!(h.state().history_id, before);
    }

    #[test]
    fn after_delay_fires_on_tick() {
        let (h, a, b, _) = two_frames();
        run(&h, "proto.interaction.add", json!({"id": a, "trigger": {"type": "afterDelay", "ms": 500}, "action": {"type": "navigate", "dest": b}}));
        let p = h.presenter(Some(a)).unwrap();
        assert!(!p.tick(100_000.0));
        assert_eq!(p.state().frame, a);
        assert!(!p.tick(100_300.0));
        assert!(p.tick(100_600.0));
        assert_eq!(p.state().frame, b);
    }

    #[test]
    fn key_trigger_and_overlay_open_close() {
        let (h, a, _, btn) = two_frames();
        let c = run(&h, "node.create", json!({"type": "frame", "x": 800, "y": 0, "width": 80, "height": 80, "name": "Sheet"}))["id"].as_u64().unwrap();
        run(&h, "proto.interaction.add", json!({"id": btn, "trigger": {"type": "keyPress", "key": "Space"}, "action": {"type": "openOverlay", "dest": c}}));
        let p = h.presenter(Some(a)).unwrap();
        assert!(p.key("Space".into()));
        let s = p.state();
        assert_eq!((s.frame, s.overlay_count), (a, 1));
        assert!(p.render(300, 400).is_ok());
        // Tapping outside the overlay closes it.
        assert!(p.tap(1.0, 1.0));
        assert_eq!(p.state().overlay_count, 0);
        assert!(!p.key("Q".into()));
    }

    #[test]
    fn drag_scrolls_a_frame_with_overflow_and_clamps() {
        let h = DocumentHandle::new_document("S".into(), false);
        let f = run(&h, "node.create", json!({"type": "frame", "x": 0, "y": 0, "width": 200, "height": 300}))["id"].as_u64().unwrap();
        run(&h, "node.set", json!({"id": f, "props": {"overflow": "vertical"}}));
        run(&h, "node.create", json!({"type": "rectangle", "parent": f, "x": 0, "y": 0, "width": 200, "height": 900}));
        let p = h.presenter(Some(f)).unwrap();
        let g0 = p.state().generation;
        let _ = p.press(100.0, 150.0, true);
        assert!(p.drag(0.0, -100.0));
        assert!(p.state().generation > g0);
        // Far past the end: clamps at the bottom (600 of overflow), then nothing moves.
        assert!(p.drag(0.0, -10_000.0));
        assert!(!p.drag(0.0, -10.0));
        // Dragging down scrolls back up.
        assert!(p.drag(0.0, 50.0));
        assert!(!p.press(100.0, 150.0, false));
    }

    #[test]
    fn on_press_reverts_when_the_finger_lifts() {
        let (h, a, b, btn) = two_frames();
        run(&h, "proto.interaction.clear", json!({"ids": [btn]}));
        run(&h, "proto.interaction.add", json!({"id": btn, "trigger": {"type": "onPress"}, "action": {"type": "navigate", "dest": b}}));
        let p = h.presenter(Some(a)).unwrap();
        let (x, y) = centre(&p.hotspots()[0]);
        assert!(p.press(x, y, true));
        assert_eq!(p.state().frame, b);
        assert!(p.press(x, y, false));
        assert_eq!(p.state().frame, a);
    }

    #[test]
    fn no_frames_is_an_error_and_hostile_input_is_harmless() {
        let h = DocumentHandle::new_document("Empty".into(), false);
        assert!(h.presenter(None).is_err());
        let (h, a, _, _) = two_frames();
        let p = h.presenter(Some(a)).unwrap();
        for (x, y) in [(f64::NAN, 1.0), (f64::INFINITY, f64::NEG_INFINITY), (-1e30, 1e30)] {
            let _ = (p.tap(x, y), p.press(x, y, true), p.press(x, y, false), p.drag(x, y));
        }
        assert!(!p.tick(f64::NAN));
        assert!(!p.key(String::new()));
        assert!(p.render(10, 10).is_ok());
    }

    #[test]
    fn key_parsing() {
        let (k, m) = parse_key("Shift+K");
        assert_eq!((k.as_str(), m.shift, m.ctrl), ("K", true, false));
        assert_eq!(parse_key("+").0, "+");
        assert_eq!(parse_key("").0, "");
    }

    #[test]
    fn overlay_rects() {
        let base = GRect::new(0.0, 0.0, 100.0, 200.0);
        let r = overlay_rect(OverlayPosition::Center, base, (40.0, 40.0), None, None);
        assert_eq!((r.x0, r.y0), (30.0, 80.0));
        let r = overlay_rect(OverlayPosition::BottomRight, base, (40.0, 40.0), None, None);
        assert_eq!((r.x0, r.y0), (60.0, 160.0));
        let anchor = GRect::new(10.0, 10.0, 30.0, 20.0);
        let r = overlay_rect(OverlayPosition::Manual, base, (40.0, 40.0), Some(anchor), None);
        assert_eq!((r.x0, r.y0), (10.0, 20.0));
    }
}
