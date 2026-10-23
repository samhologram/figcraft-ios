//! Prints tables for `apple/scripts`: `cargo run --example dump -- engine|menus|tools|excluded`.
//! engine: id, label, menu path, params doc; menus: top-level menu and its command ids; tools: ToolId ids.
fn main() {
    let what = std::env::args().nth(1).unwrap_or_default();
    match what.as_str() {
        "engine" => {
            for c in figcraft_apple::command_catalog() {
                println!("{}\t{}\t{}\t{}", c.id, c.label, c.menu.join(">"), c.params.replace(['\n', '\t'], " "));
            }
        }
        "menus" => {
            for m in figcraft_apple::menu_layout() {
                let mut ids = Vec::new();
                for e in &m.items {
                    if e.kind == "command" {
                        ids.push(e.id.clone());
                    }
                    ids.extend(e.children.iter().map(|c| c.id.clone()));
                }
                println!("{}\t{}", m.title, ids.join(" "));
            }
        }
        "tools" => {
            for g in figcraft_apple::tool_groups() {
                for t in g.tools {
                    println!("{}\t{}\t{}", t.id, t.command, g.key);
                }
            }
        }
        "toolids" => {
            for t in figcraft_engine::ToolId::ALL {
                println!("{}", t.id());
            }
        }
        _ => eprintln!("usage: dump engine|menus|tools|toolids"),
    }
}
