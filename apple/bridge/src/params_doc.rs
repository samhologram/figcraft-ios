//! Structured view of the engine's free-form `params` docs, so the Swift app can generate a native
//! form for ANY command, including commands added by future upstream syncs.
//!
//! The docs follow a loose grammar. Typical shapes:
//!
//! ```text
//! {rating: 0..5, ids?, advance?: bool}
//! {flag: pick|reject|none, ids?, advance?: bool}
//! {ids: [id], active?: id, mode?: replace|add|toggle|range} - free text after the object
//! {} -> {result}
//! ```
//!
//! Parsing is best effort and never panics: whatever cannot be understood becomes a field of kind
//! `"json"` (the app then offers a raw JSON editor for it). A field with an EMPTY `key` stands for
//! "free-form extra params" (open-ended doc, or a doc that is not an object at all); its `doc` carries
//! the raw fragment.

use crate::ParamField;

// ---------------------------------------------------------------------------------------------
// Scanning helpers (all on `&[char]`, so no byte-boundary panics)
// ---------------------------------------------------------------------------------------------

fn is_open(c: char) -> bool {
    matches!(c, '{' | '[' | '(')
}
fn is_close(c: char) -> bool {
    matches!(c, '}' | ']' | ')')
}

/// Walk `chars` calling `f(index, char, depth)` for every char outside double quotes; `depth` is the
/// bracket depth BEFORE the char is applied (an opener is seen at the outer depth).
fn walk(chars: &[char], mut f: impl FnMut(usize, char, usize)) {
    let (mut depth, mut in_str) = (0usize, false);
    for (i, &c) in chars.iter().enumerate() {
        if in_str {
            if c == '"' {
                in_str = false;
            }
            continue;
        }
        if c == '"' {
            in_str = true;
            continue;
        }
        f(i, c, depth);
        if is_open(c) {
            depth += 1;
        } else if is_close(c) {
            depth = depth.saturating_sub(1);
        }
    }
}

fn text(chars: &[char]) -> String {
    chars.iter().collect()
}

fn sub(chars: &[char], from: usize, to: usize) -> &[char] {
    chars.get(from..to.min(chars.len())).unwrap_or(&[])
}

fn trim_chars(chars: &[char]) -> &[char] {
    let mut s = 0;
    let mut e = chars.len();
    while s < e && chars.get(s).is_some_and(|c| c.is_whitespace()) {
        s += 1;
    }
    while e > s && chars.get(e - 1).is_some_and(|c| c.is_whitespace()) {
        e -= 1;
    }
    sub(chars, s, e)
}

/// Split at top-level (depth 0, outside quotes) occurrences of `sep`.
fn split_top(chars: &[char], sep: char) -> Vec<&[char]> {
    let mut cuts = Vec::new();
    walk(chars, |i, c, depth| {
        if depth == 0 && c == sep {
            cuts.push(i);
        }
    });
    let mut out = Vec::new();
    let mut start = 0;
    for cut in cuts {
        out.push(sub(chars, start, cut));
        start = cut + 1;
    }
    out.push(sub(chars, start, chars.len()));
    out
}

/// Remove `( ... )` groups that sit at depth 0 (free-text comments), respecting quotes.
fn strip_comments(chars: &[char]) -> Vec<char> {
    let mut skip = vec![false; chars.len()];
    let (mut depth, mut in_str, mut paren_start) = (0usize, false, None::<usize>);
    for (i, &c) in chars.iter().enumerate() {
        if in_str {
            if c == '"' {
                in_str = false;
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '(' if depth == 0 => {
                paren_start = Some(i);
                depth += 1;
            }
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => {
                depth = depth.saturating_sub(1);
                if depth == 0
                    && c == ')'
                    && let Some(s) = paren_start.take()
                {
                    for slot in skip.iter_mut().take(i + 1).skip(s) {
                        *slot = true;
                    }
                }
            }
            _ => {}
        }
    }
    chars.iter().zip(skip).filter(|(_, s)| !*s).map(|(c, _)| *c).collect()
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}...", s.chars().take(max).collect::<String>()) }
}

/// "cornerRadius" / "corner_radius" -> "Corner radius".
pub fn humanize(key: &str) -> String {
    let mut out = String::new();
    let mut prev_lower = false;
    for c in key.chars() {
        if c == '_' || c == '-' || c == '.' {
            if !out.ends_with(' ') && !out.is_empty() {
                out.push(' ');
            }
            prev_lower = false;
            continue;
        }
        if c.is_uppercase() && prev_lower {
            out.push(' ');
            out.extend(c.to_lowercase());
        } else if out.is_empty() {
            out.extend(c.to_uppercase());
        } else {
            out.push(c);
        }
        prev_lower = c.is_lowercase() || c.is_ascii_digit();
    }
    out
}

fn field(key: &str, kind: &str, doc: &str) -> ParamField {
    ParamField {
        key: key.to_string(),
        kind: kind.to_string(),
        min: None,
        max: None,
        default_json: None,
        choices: Vec::new(),
        label: humanize(key),
        is_optional: false,
        doc: doc.to_string(),
    }
}

fn free_form(doc: &str) -> ParamField {
    let mut f = field("", "json", doc.trim());
    f.is_optional = true;
    f.label = clip(doc.trim(), 140);
    f
}

// ---------------------------------------------------------------------------------------------
// Whole doc
// ---------------------------------------------------------------------------------------------

/// Parse a `params` doc into fields. Empty for `{}` or an empty doc.
pub fn parse_params(doc: &str) -> Vec<ParamField> {
    let all: Vec<char> = doc.chars().collect();
    let all = trim_chars(&all);
    if all.is_empty() {
        return Vec::new();
    }
    if all.first() != Some(&'{') {
        return vec![free_form(doc)];
    }
    // Matching close of the first object.
    let mut close = None;
    walk(all, |i, c, depth| {
        if close.is_none() && c == '}' && depth == 1 {
            close = Some(i);
        }
    });
    let Some(close) = close else { return vec![free_form(doc)] };
    let body = sub(all, 1, close);
    if trim_chars(body).is_empty() {
        return Vec::new();
    }
    let mut fields = Vec::new();
    let mut open_ended = false;
    for entry in split_top(body, ',') {
        let entry = trim_chars(entry);
        if entry.is_empty() {
            continue;
        }
        match parse_entry(entry) {
            Some(f) => fields.push(f),
            None => open_ended = true,
        }
    }
    if open_ended {
        fields.push(free_form(doc));
    }
    fields
}

/// One entry: `key`, `key?`, `key: type`, `key?: type = default`. `None` = not a key (an ellipsis or
/// free text): the doc is open-ended.
fn parse_entry(entry: &[char]) -> Option<ParamField> {
    let key_len = entry.iter().take_while(|c| c.is_ascii_alphanumeric() || **c == '_').count();
    if key_len == 0 {
        return None;
    }
    let key = text(sub(entry, 0, key_len));
    let mut rest = trim_chars(sub(entry, key_len, entry.len()));
    let mut optional = false;
    if rest.first() == Some(&'?') {
        optional = true;
        rest = trim_chars(sub(rest, 1, rest.len()));
    }
    let raw = text(entry);
    let mut f = field(&key, "json", &raw);
    f.is_optional = optional;
    match rest.first() {
        // a bare key, or one followed by a parenthesised comment: infer from the name
        None | Some('(') => {
            let k = infer_kind(&key, &mut f);
            f.kind = k;
        }
        Some(':') => {
            let ty = sub(rest, 1, rest.len());
            classify(&mut f, ty);
            if f.kind == "json" && matches!(key.as_str(), "ids" | "id" | "color") {
                let k = infer_kind(&key, &mut f);
                f.kind = k;
            }
        }
        // `id|null`, `name | names`: alternatives of the key; not editable generically
        Some(_) => f.is_optional = true,
    }
    Some(f)
}

/// Kind of a key that has no type text, from its name (may set `min`).
fn infer_kind(key: &str, f: &mut ParamField) -> String {
    match key {
        "ids" => "ids",
        "id" | "start" | "dest" | "parent" | "page" => "id",
        "index" => {
            f.min = Some(0.0);
            "integer"
        }
        "name" | "text" | "title" | "label" | "caption" | "path" | "folder" | "description" | "url" => "string",
        "color" | "fill" | "stroke" | "background" => "color",
        "x" | "y" | "width" | "height" | "scale" | "zoom" | "opacity" | "radius" | "rotation" | "amount" | "gap" | "size" | "fontSize" => "number",
        _ => "json",
    }
    .to_string()
}

/// A default that is a JSON literal: number, bool or quoted string.
fn literal_json(d: &str) -> Option<String> {
    let d = d.trim();
    if d == "true" || d == "false" {
        return Some(d.to_string());
    }
    if let Some(n) = parse_num(d) {
        return Some(num_json(n));
    }
    if d.len() >= 2 && d.starts_with('"') && d.ends_with('"') {
        let inner: String = d.chars().skip(1).take(d.chars().count() - 2).collect();
        if !inner.contains('"') {
            return serde_json::to_string(&inner).ok();
        }
    }
    None
}

fn num_json(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { n.to_string() }
}

fn parse_num(s: &str) -> Option<f64> {
    let s = s.trim();
    if s.is_empty() || !s.chars().all(|c| c.is_ascii_digit() || matches!(c, '.' | '-' | '+')) {
        return None;
    }
    s.parse::<f64>().ok().filter(|v| v.is_finite())
}

/// Leading number of `s` (digits, sign, one dot) and the rest.
fn split_number(s: &str) -> Option<(f64, &str)> {
    let s = s.trim_start();
    let mut end = 0;
    let mut dot = false;
    for (i, c) in s.char_indices() {
        let ok = c.is_ascii_digit() || (i == 0 && matches!(c, '-' | '+')) || (c == '.' && !dot && s[i + 1..].starts_with(|n: char| n.is_ascii_digit()));
        if !ok {
            break;
        }
        if c == '.' {
            dot = true;
        }
        end = i + c.len_utf8();
    }
    let n = s.get(..end)?.parse::<f64>().ok().filter(|v| v.is_finite())?;
    Some((n, s.get(end..)?))
}

fn is_word(w: &str) -> bool {
    !w.is_empty() && w.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

/// Fill `f.kind`, range, choices and default from the type text after the `:`.
fn classify(f: &mut ParamField, ty: &[char]) {
    let core = strip_comments(ty);
    let core = trim_chars(&core).to_vec();
    // `type = default`: the last top-level `=`.
    let mut eq = None;
    walk(&core, |i, c, depth| {
        if depth == 0 && c == '=' {
            eq = Some(i);
        }
    });
    let (ty_chars, def) = match eq {
        Some(i) => (trim_chars(sub(&core, 0, i)).to_vec(), Some(text(trim_chars(sub(&core, i + 1, core.len()))))),
        None => (core.clone(), None),
    };
    let ty = text(trim_chars(&ty_chars));
    if let Some(d) = &def {
        f.default_json = literal_json(d);
        f.is_optional = true;
    }
    let lower = ty.to_ascii_lowercase();

    match lower.as_str() {
        "bool" | "boolean" => {
            f.kind = "bool".into();
            return;
        }
        "string" | "str" | "text" | "name" => {
            f.kind = "string".into();
            return;
        }
        "id" | "nodeid" => {
            f.kind = "id".into();
            return;
        }
        "color" => {
            f.kind = "color".into();
            return;
        }
        "index" | "int" | "integer" | "n" | "count" => {
            f.kind = "integer".into();
            f.min = Some(0.0);
            return;
        }
        "number" | "float" | "f64" | "f32" | "degrees" | "px" => {
            f.kind = "number".into();
            return;
        }
        "[id]" | "[ids]" | "[nodeid]" | "[id,...]" | "[id,\u{2026}]" | "[..]" | "[...]" | "[\u{2026}]" => {
            f.kind = "ids".into();
            return;
        }
        _ => {}
    }

    // Range: `0..5`, `-100..100`, `0.1..1000`.
    if let Some((lo, rest)) = split_number(&ty)
        && let Some(rest) = rest.trim_start().strip_prefix("..")
        && !rest.starts_with('.')
        && let Some((hi, tail)) = split_number(rest)
        && hi >= lo
    {
        f.min = Some(lo);
        f.max = Some(hi);
        let whole = |s: &str| !s.contains('.');
        let lo_text = ty.split("..").next().unwrap_or("");
        let hi_len = rest.len() - tail.len();
        let hi_text = rest.get(..hi_len).unwrap_or("");
        let def_integral = f.default_json.as_deref().is_none_or(|d| d.parse::<f64>().is_ok_and(|v| v.fract() == 0.0));
        f.kind = if whole(lo_text) && whole(hi_text) && def_integral { "integer" } else { "number" }.into();
        return;
    }

    // Choices: `a|b|c` or `"a"|"b"` of plain words (numbers allowed); `null` is ignored.
    let chars: Vec<char> = ty.chars().collect();
    let alts = split_top(&chars, '|');
    if alts.len() >= 2 {
        let mut choices = Vec::new();
        let mut ok = true;
        let mut free = false;
        for alt in alts {
            let a = text(trim_chars(alt));
            let a = a.trim_matches('"').to_string();
            if a == "null" || a.is_empty() {
                continue;
            }
            if matches!(a.as_str(), "string" | "name" | "text") {
                free = true;
                continue;
            }
            if is_word(&a) {
                choices.push(a);
            } else {
                ok = false;
                break;
            }
        }
        if ok && choices.len() >= 2 {
            if f.default_json.is_none()
                && let Some(d) = def.as_deref().map(str::trim).filter(|d| choices.iter().any(|c| c == d))
            {
                f.default_json = serde_json::to_string(d).ok();
            }
            f.kind = if free { "string" } else { "choice" }.into();
            f.choices = choices;
            return;
        }
        if ok && choices.len() == 1 && lower.contains("null") {
            // `x | null`: classify x
            if let Some(first) = ty.split('|').map(str::trim).find(|a| *a != "null") {
                let mut g = field(&f.key, "json", "");
                classify(&mut g, &first.chars().collect::<Vec<_>>());
                f.kind = g.kind;
                f.min = g.min;
                f.max = g.max;
                f.choices = g.choices;
                f.is_optional = true;
            }
            return;
        }
    }

    // A lone quoted literal documents a free-text value.
    if ty.len() >= 2 && ty.starts_with('"') && ty.ends_with('"') {
        f.kind = "string".into();
        return;
    }
    // Fallback: edited as raw JSON.
    f.kind = "json".into();
}

// ---------------------------------------------------------------------------------------------
// Platform support
// ---------------------------------------------------------------------------------------------

const IOS_EXCLUDED: &str = include_str!("../ios-excluded-commands.txt");

/// `(id, reason)` pairs from `ios-excluded-commands.txt` (`id<TAB>reason`; `#` comments).
pub fn excluded_commands() -> Vec<(String, String)> {
    IOS_EXCLUDED
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (id, reason) = line.split_once('\t').unwrap_or((line, ""));
            let id = id.trim();
            (!id.is_empty()).then(|| (id.to_string(), reason.trim().to_string()))
        })
        .collect()
}

/// Parsed parameters of a command (empty for unknown ids and commands without params).
pub fn fields_for(id: &str) -> Vec<ParamField> {
    match figcraft_engine::cmd::find_command(id) {
        Some(spec) => parse_params(spec.params),
        None => Vec::new(),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn one(doc: &str) -> ParamField {
        let mut v = parse_params(doc);
        assert_eq!(v.len(), 1, "{doc}: {v:?}");
        v.remove(0)
    }

    #[test]
    fn numbers_and_ranges() {
        let f = one("{rating: 0..5}");
        assert_eq!((f.key.as_str(), f.kind.as_str(), f.min, f.max), ("rating", "integer", Some(0.0), Some(5.0)));
        assert!(!f.is_optional);
        let f = one("{amount?: 0.1..1000 = 1}");
        assert_eq!((f.kind.as_str(), f.min, f.max, f.default_json.as_deref()), ("number", Some(0.1), Some(1000.0), Some("1")));
        assert!(f.is_optional);
        let f = one("{x: -100..100}");
        assert_eq!((f.kind.as_str(), f.min), ("integer", Some(-100.0)));
    }

    #[test]
    fn choices_bools_strings_ids() {
        let v = parse_params("{flag: pick|reject|none, ids?, advance?: bool}");
        assert_eq!(v.len(), 3);
        assert_eq!((v[0].kind.as_str(), v[0].choices.clone()), ("choice", vec!["pick".to_string(), "reject".into(), "none".into()]));
        assert_eq!((v[1].key.as_str(), v[1].kind.as_str(), v[1].is_optional), ("ids", "ids", true));
        assert_eq!((v[2].kind.as_str(), v[2].is_optional), ("bool", true));
        assert_eq!(one("{name: string}").kind, "string");
        assert_eq!(one("{ids: [id]}").kind, "ids");
        assert_eq!(one("{ids: [..]}").kind, "ids");
        assert_eq!(one("{mode?: \"a\"|\"b\" = \"a\"}").default_json.as_deref(), Some("\"a\""));
        assert_eq!(one("{id: id | null}").kind, "id");
    }

    #[test]
    fn empty_open_and_odd_docs() {
        assert!(parse_params("").is_empty());
        assert!(parse_params("{}").is_empty());
        assert!(parse_params("{} -> [{name}]").is_empty());
        let f = one("no object here");
        assert_eq!(f.key, "");
        let v = parse_params("{a: bool, ...}");
        assert_eq!(v.len(), 2);
        assert_eq!(v[1].key, "");
        // comments and nested braces do not split fields
        let v = parse_params("{name | names, group: name (\"\" = none), rect?: [x0,y0,x1,y1] normalized}");
        assert_eq!(v.iter().map(|f| f.key.as_str()).collect::<Vec<_>>(), ["name", "group", "rect"]);
        assert_eq!(v[2].kind, "json");
    }

    #[test]
    fn hostile_input_never_panics() {
        for doc in ["{", "}", "{\"", "{a:", "{a: 1..", "{a: ..5}", "{:::}", "{\u{1F600}: x}", "{a: \u{2026}|\u{2026}}", "{((((", "{a?:?=}", "{=}", "{a: 1..1..1}"] {
            let _ = parse_params(doc);
        }
    }

    #[test]
    fn whole_catalog_parses() {
        let mut fields = 0usize;
        let mut json_fields = 0usize;
        for c in figcraft_engine::all_commands() {
            for f in parse_params(c.params) {
                fields += 1;
                if f.kind == "json" {
                    json_fields += 1;
                }
                assert!(f.min.zip(f.max).is_none_or(|(a, b)| a <= b), "{}: {f:?}", c.id);
            }
        }
        assert!(fields > 100, "only {fields} fields parsed");
        assert!(json_fields < fields, "nothing was understood");
    }

    #[test]
    fn excluded_file_is_well_formed() {
        for line in IOS_EXCLUDED.lines().filter(|l| !l.trim().is_empty() && !l.starts_with('#')) {
            let (id, reason) = line.split_once('\t').unwrap_or((line, ""));
            assert!(!id.is_empty() && !reason.trim().is_empty(), "bad line: {line:?}");
            assert!(figcraft_engine::cmd::find_command(id.trim()).is_some() , "unknown id in excluded list: {id}");
        }
    }
}
