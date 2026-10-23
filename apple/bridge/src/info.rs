//! Static tables the Swift app generates its UI from: command catalog, menus, tool groups, templates.

use figcraft_engine::ToolId;
use figcraft_engine::catalog::{self, MENU, SEP};
use figcraft_engine::keymap::{self, Platform};

use crate::params_doc::humanize;
use crate::{CommandInfo, MenuEntry, MenuSection, TemplateInfo, ToolGroup, ToolInfo};

pub fn shortcut(id: &str) -> Option<String> {
    keymap::primary(id, Platform::Mac).map(str::to_string)
}

pub fn command_catalog() -> Vec<CommandInfo> {
    figcraft_engine::all_commands()
        .iter()
        .map(|c| CommandInfo {
            id: c.id.to_string(),
            label: c.label.to_string(),
            menu: c.menu().map(|m| m.split('/').map(str::to_string).collect()).unwrap_or_default(),
            shortcut: shortcut(c.id),
            params: c.params.to_string(),
            undoable: c.history,
        })
        .collect()
}

fn entry(kind: &str, id: &str, label: &str) -> MenuEntry {
    MenuEntry { kind: kind.into(), id: id.into(), label: label.into(), children: Vec::new() }
}

/// `catalog::MENU` grouped by top-level menu in order of first appearance; a path below the top
/// level (`Edit/Copy as`) becomes a submenu at the place of its first item (deeper paths flatten).
pub fn menu_layout() -> Vec<MenuSection> {
    let mut sections: Vec<MenuSection> = Vec::new();
    for item in MENU {
        let mut parts = item.menu.split('/');
        let top = parts.next().unwrap_or("").to_string();
        let sub: Vec<&str> = parts.collect();
        let idx = match sections.iter().position(|s| s.title == top) {
            Some(i) => i,
            None => {
                sections.push(MenuSection { title: top.clone(), items: Vec::new() });
                sections.len() - 1
            }
        };
        let Some(section) = sections.get_mut(idx) else { continue };
        let leaf = if item.label == SEP { entry("separator", "", "") } else { entry("command", item.id, item.label) };
        if sub.is_empty() {
            section.items.push(leaf);
            continue;
        }
        if leaf.kind == "separator" {
            continue;
        }
        let title = sub.first().copied().unwrap_or("").to_string();
        match section.items.iter_mut().find(|e| e.kind == "submenu" && e.label == title) {
            Some(e) => e.children.push(leaf),
            None => {
                let mut e = entry("submenu", "", &title);
                e.children.push(leaf);
                section.items.push(e);
            }
        }
    }
    sections
}

fn tool_command(t: ToolId) -> String {
    let c = format!("tool.{}", t.id());
    if figcraft_engine::find_command(&c).is_some() {
        c
    } else if t == ToolId::Eyedropper {
        "edit.pickColor".into()
    } else {
        c
    }
}

fn tool_info(t: ToolId) -> ToolInfo {
    let command = tool_command(t);
    let label = catalog::items().find(|m| m.id == command).map(|m| m.label.to_string()).unwrap_or_else(|| t.label().to_string());
    ToolInfo { id: t.id().into(), shortcut: shortcut(&command), command, label }
}

const TOOLBAR_SRC: &str = include_str!("../../../crates/ui-egui/src/toolbar.rs");

/// `(key, name, [ToolId variant names])` for every group of `const GROUPS` in the desktop toolbar.
/// Never panics; unparseable input gives an empty list.
pub fn parse_toolbar_groups(src: &str) -> Vec<(String, String, Vec<String>)> {
    let Some(start) = src.find("const GROUPS") else { return Vec::new() };
    let body = src.get(start..).unwrap_or("");
    // The array ends at the first `];` at the start of a line.
    let end = body.find("\n];").unwrap_or(body.len());
    let body = body.get(..end).unwrap_or("");
    let mut out = Vec::new();
    for chunk in body.split("Group {").skip(1) {
        let Some(key) = quoted_after(chunk, "key:") else { continue };
        let name = quoted_after(chunk, "tr_noop(").or_else(|| quoted_after(chunk, "name:")).unwrap_or_default();
        let Some(ti) = chunk.find("tools:") else { continue };
        let tools_src = chunk.get(ti..).unwrap_or("");
        let mut tools = Vec::new();
        for part in tools_src.split("ToolId::").skip(1) {
            let ident: String = part.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
            if !ident.is_empty() {
                tools.push(ident);
            }
        }
        if !tools.is_empty() {
            out.push((key, name, tools));
        }
    }
    out
}

fn quoted_after(s: &str, marker: &str) -> Option<String> {
    let i = s.find(marker)? + marker.len();
    let rest = s.get(i..)?;
    let q = rest.find('"')? + 1;
    // The quote must follow the marker closely (no other token in between).
    if rest.get(..q.saturating_sub(1))?.chars().any(|c| !c.is_whitespace() && c != '(') {
        return None;
    }
    let tail = rest.get(q..)?;
    let e = tail.find('"')?;
    tail.get(..e).map(str::to_string)
}

pub fn tool_groups() -> Vec<ToolGroup> {
    let mut groups = Vec::new();
    for (key, name, idents) in parse_toolbar_groups(TOOLBAR_SRC) {
        let tools: Vec<ToolInfo> =
            idents.iter().filter_map(|i| ToolId::ALL.into_iter().find(|t| format!("{t:?}") == *i)).map(tool_info).collect();
        if !tools.is_empty() {
            let name = if name.is_empty() { humanize(&key) } else { name };
            groups.push(ToolGroup { key, name, tools });
        }
    }
    if groups.is_empty() {
        groups.push(ToolGroup { key: "tools".into(), name: "Tools".into(), tools: ToolId::ALL.into_iter().map(tool_info).collect() });
    }
    groups
}

pub fn templates() -> Vec<TemplateInfo> {
    figcraft_engine::templates::TEMPLATES
        .iter()
        .map(|t| TemplateInfo {
            id: t.id.into(),
            name: t.name.into(),
            description: t.description.into(),
            kind: t.kind.id().into(),
            size: t.size.into(),
        })
        .collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_desktop_toolbar() {
        let g = parse_toolbar_groups(TOOLBAR_SRC);
        assert!(g.len() >= 5, "{g:?}");
        assert_eq!(g[0].0, "move");
        assert!(g[0].2.contains(&"Hand".to_string()));
        let groups = tool_groups();
        assert_eq!(groups[0].key, "move");
        assert_eq!(groups[0].tools[0].id, "move");
        assert_eq!(groups[0].tools[0].command, "tool.move");
        assert!(groups.iter().flat_map(|g| &g.tools).any(|t| t.id == "shapeBuilder"));
    }

    #[test]
    fn parser_never_panics_on_junk() {
        for s in ["", "const GROUPS", "const GROUPS = [Group {", "Group { key: \"", "const GROUPS: &[Group] = &[Group { key: \"a\", tools: &[(ToolId::", "\u{1F600}const GROUPS\u{1F600}Group {key:\"\u{1F600}"] {
            let _ = parse_toolbar_groups(s);
        }
        assert!(parse_toolbar_groups("nothing").is_empty());
    }

    #[test]
    fn every_tool_command_exists() {
        for t in ToolId::ALL {
            let c = tool_command(t);
            assert!(figcraft_engine::find_command(&c).is_some(), "{c}");
        }
    }

    #[test]
    fn menu_layout_has_submenus_and_all_ids() {
        let m = menu_layout();
        assert_eq!(m.first().map(|s| s.title.as_str()), Some("File"));
        let edit = m.iter().find(|s| s.title == "Edit").unwrap();
        assert!(edit.items.iter().any(|e| e.kind == "submenu" && e.label == "Copy as" && !e.children.is_empty()));
        let mut n = 0;
        for s in &m {
            for e in &s.items {
                n += if e.kind == "submenu" { e.children.len() } else { usize::from(e.kind == "command") };
            }
        }
        assert_eq!(n, catalog::items().count());
    }

    #[test]
    fn catalog_and_templates() {
        let c = command_catalog();
        assert!(c.len() > 300);
        let undo = c.iter().find(|c| c.id == "edit.undo").unwrap();
        assert_eq!(undo.menu, vec!["Edit".to_string()]);
        assert!(undo.shortcut.is_some());
        assert!(templates().iter().any(|t| t.id == "mobile-app"));
    }
}
