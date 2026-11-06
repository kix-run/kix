//! Convert the YAML stream `helm template` prints to a JSON array, one
//! element per document.
//!
//! Kix used to run `yq eval-all -o=json '[.]'` for this, and the library
//! reads the result with `builtins.fromJSON`. A Nix value depends on the
//! exact JSON text: `1` is an integer and `1.5` a float. So this module
//! prints each scalar as yq 4 printed it, because a different number would
//! change the manifests of every chart that renders one:
//!
//! - A plain scalar gets its type from go-yaml's rules, which yq uses.
//!   `0755` is an integer, `08` and `1e3` are floats, `yes` is a string.
//! - yq prints an integer by reading its text in base 10 unless it starts
//!   with `0x` or `0o`, so `0755` prints as `755`.
//! - yq prints a float in Go's shortest form, without a decimal point when
//!   the value is whole, so `1.0` prints as `1` and Nix reads an integer.
//!   It switches to exponent form below 1e-6 and from 1e21.
//!
//! A scalar that yq could not print, such as `.inf` or an integer beyond
//! 64 bits, is an error here too. Such a chart never rendered before.

use std::collections::HashMap;
use std::fmt::Write as _;

use yaml_rust2::parser::{Event, Parser, Tag};
use yaml_rust2::scanner::TScalarStyle;

/// A YAML stream that Kix cannot convert to JSON.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct YamlError(String);

/// One YAML node with the type yq would print it as.
#[derive(Debug, Clone)]
enum Node {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Seq(Vec<Node>),
    /// Entries in document order. A key can repeat, as yq prints it, and
    /// `builtins.fromJSON` keeps the last value.
    Map(Vec<(String, Node)>),
}

enum Frame {
    Seq {
        anchor: usize,
        items: Vec<Node>,
    },
    Map {
        anchor: usize,
        entries: Vec<(String, Node)>,
        key: Option<Key>,
    },
}

enum Key {
    Name(String),
    /// The plain key `<<`, whose value is merged into the mapping.
    Merge,
}

/// Convert a `helm template` YAML stream to the JSON text of an array.
pub fn to_json(yaml: &str) -> Result<String, YamlError> {
    let mut parser = Parser::new_from_str(yaml);
    let mut docs: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    let mut stack: Vec<Frame> = Vec::new();
    let mut anchors: HashMap<usize, (Node, Option<String>)> = HashMap::new();

    loop {
        let (event, mark) = parser
            .next_token()
            .map_err(|e| YamlError(format!("the chart's output is not valid YAML: {e}")))?;
        let at = || format!("line {} column {}", mark.line(), mark.col() + 1);
        let (node, key_text) = match event {
            Event::StreamEnd => break,
            Event::Nothing | Event::StreamStart => continue,
            Event::DocumentStart => {
                root = None;
                continue;
            }
            Event::DocumentEnd => {
                docs.push(root.take().unwrap_or(Node::Null));
                continue;
            }
            Event::Scalar(value, style, anchor, tag) => {
                let node = scalar(&value, style, tag.as_ref())
                    .map_err(|e| YamlError(format!("{e} at {}", at())))?;
                let merge = style == TScalarStyle::Plain && tag.is_none() && value == "<<";
                if anchor > 0 {
                    anchors.insert(anchor, (node.clone(), Some(value.clone())));
                }
                (
                    node,
                    Some(if merge {
                        KeyText::Merge
                    } else {
                        KeyText::Name(value)
                    }),
                )
            }
            Event::Alias(id) => {
                let (node, text) = anchors
                    .get(&id)
                    .cloned()
                    .ok_or_else(|| YamlError(format!("an alias names no anchor at {}", at())))?;
                (node, text.map(KeyText::Name))
            }
            Event::SequenceStart(anchor, _) => {
                stack.push(Frame::Seq {
                    anchor,
                    items: Vec::new(),
                });
                continue;
            }
            Event::MappingStart(anchor, _) => {
                stack.push(Frame::Map {
                    anchor,
                    entries: Vec::new(),
                    key: None,
                });
                continue;
            }
            Event::SequenceEnd | Event::MappingEnd => {
                let (anchor, node) = match stack.pop() {
                    Some(Frame::Seq { anchor, items }) => (anchor, Node::Seq(items)),
                    Some(Frame::Map {
                        anchor, entries, ..
                    }) => (anchor, Node::Map(entries)),
                    None => return Err(YamlError(format!("unbalanced collection at {}", at()))),
                };
                if anchor > 0 {
                    anchors.insert(anchor, (node.clone(), None));
                }
                (node, None)
            }
        };
        match stack.last_mut() {
            None => root = Some(node),
            Some(Frame::Seq { items, .. }) => items.push(node),
            Some(Frame::Map { entries, key, .. }) => match key.take() {
                None => {
                    *key = Some(match key_text {
                        Some(KeyText::Merge) => Key::Merge,
                        Some(KeyText::Name(name)) => Key::Name(name),
                        // yq prints a mapping or sequence used as a key as "".
                        None => Key::Name(String::new()),
                    })
                }
                Some(Key::Name(name)) => entries.push((name, node)),
                Some(Key::Merge) => merge(entries, node),
            },
        }
    }

    let mut out = String::new();
    out.push('[');
    for (i, doc) in docs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        write_json(&mut out, doc)?;
    }
    out.push(']');
    Ok(out)
}

enum KeyText {
    Name(String),
    Merge,
}

/// Merge the mapping, or each mapping in the sequence, that a `<<` key
/// names into `entries`. Like yq without `--yaml-fix-merge-anchor-to-spec`,
/// a merged key replaces one the mapping already has.
fn merge(entries: &mut Vec<(String, Node)>, value: Node) {
    let maps = match value {
        Node::Seq(items) => items,
        other => vec![other],
    };
    for map in maps {
        let Node::Map(merged) = map else { continue };
        for (k, v) in merged {
            match entries.iter_mut().find(|(name, _)| *name == k) {
                Some(entry) => entry.1 = v,
                None => entries.push((k, v)),
            }
        }
    }
}

/// Return the node a scalar becomes, typed as yq types it.
fn scalar(value: &str, style: TScalarStyle, tag: Option<&Tag>) -> Result<Node, String> {
    if let Some(tag) = tag
        && tag.handle == "tag:yaml.org,2002:"
    {
        return match tag.suffix.as_str() {
            "null" => Ok(Node::Null),
            "bool" => Ok(Node::Bool(matches!(
                value.to_ascii_lowercase().as_str(),
                "true" | "yes" | "on" | "y"
            ))),
            "int" => yq_int(value).map(Node::Int),
            "float" => go_float(value).map(Node::Float),
            _ => Ok(Node::Str(value.to_string())),
        };
    }
    if style != TScalarStyle::Plain {
        return Ok(Node::Str(value.to_string()));
    }
    plain(value)
}

/// Type a plain scalar by go-yaml's resolver, then convert it as yq does.
fn plain(value: &str) -> Result<Node, String> {
    match value {
        "" | "~" | "null" | "Null" | "NULL" => return Ok(Node::Null),
        "true" | "True" | "TRUE" => return Ok(Node::Bool(true)),
        "false" | "False" | "FALSE" => return Ok(Node::Bool(false)),
        "-0" | "-0.0" => return Ok(Node::Float(-0.0)),
        ".nan" | ".NaN" | ".NAN" | ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF"
        | "-.inf" | "-.Inf" | "-.INF" => {
            return Err(format!("the value {value} has no JSON form"));
        }
        _ => {}
    }
    match value.as_bytes()[0] {
        b'.' => Ok(match parse_float(value) {
            Some(f) => Node::Float(f),
            None => Node::Str(value.to_string()),
        }),
        b'+' | b'-' | b'0'..=b'9' => {
            let digits = value.replace('_', "");
            if go_int_base0(&digits).is_some() {
                return yq_int(value).map(Node::Int);
            }
            if go_uint_base0(&digits) {
                return Err(format!("the integer {value} does not fit in 64 bits"));
            }
            if yaml_style_float(&digits)
                && let Some(f) = parse_float(&digits)
            {
                return Ok(Node::Float(f));
            }
            Ok(Node::Str(value.to_string()))
        }
        _ => Ok(Node::Str(value.to_string())),
    }
}

/// Return the integer yq prints for `value`: base 16 after `0x`, base 8
/// after `0o`, and base 10 otherwise, with underscores removed.
fn yq_int(value: &str) -> Result<i64, String> {
    let s = value.replace('_', "");
    let parsed = if let Some(hex) = s.strip_prefix("0x") {
        i64::from_str_radix(hex, 16)
    } else if let Some(oct) = s.strip_prefix("0o") {
        i64::from_str_radix(oct, 8)
    } else {
        s.parse::<i64>()
    };
    parsed.map_err(|_| format!("the integer {value} has no JSON form"))
}

/// Return the float `value` names, as Go's `strconv.ParseFloat` reads it
/// once its underscores are removed.
fn go_float(value: &str) -> Result<f64, String> {
    parse_float(&value.replace('_', ""))
        .ok_or_else(|| format!("the float {value} has no JSON form"))
}

/// Parse a decimal float. Return `None` for text Go does not read as a
/// decimal float, and for a value too large for 64 bits, which Go reports
/// as out of range.
fn parse_float(s: &str) -> Option<f64> {
    let body = s.strip_prefix(['+', '-']).unwrap_or(s);
    let valid = !body.is_empty()
        && body
            .chars()
            .all(|c| c.is_ascii_digit() || "._eE+-".contains(c))
        && body.chars().any(|c| c.is_ascii_digit());
    if !valid {
        return None;
    }
    s.parse::<f64>().ok().filter(|f| f.is_finite())
}

/// Return whether Go's `strconv.ParseInt(s, 0, 64)` accepts `s`.
fn go_int_base0(s: &str) -> Option<i64> {
    let (negative, body) = match s.as_bytes().first()? {
        b'+' => (false, &s[1..]),
        b'-' => (true, &s[1..]),
        _ => (false, s),
    };
    let magnitude = go_uint_base0_value(body)?;
    if negative {
        if magnitude <= i64::MAX as u64 + 1 {
            Some((magnitude as i64).wrapping_neg())
        } else {
            None
        }
    } else {
        i64::try_from(magnitude).ok()
    }
}

/// Return whether Go's `strconv.ParseUint(s, 0, 64)` accepts `s`.
fn go_uint_base0(s: &str) -> bool {
    go_uint_base0_value(s).is_some()
}

fn go_uint_base0_value(s: &str) -> Option<u64> {
    let lower = s.to_ascii_lowercase();
    let (radix, digits) = if let Some(d) = lower.strip_prefix("0x") {
        (16, d)
    } else if let Some(d) = lower.strip_prefix("0b") {
        (2, d)
    } else if let Some(d) = lower.strip_prefix("0o") {
        (8, d)
    } else if lower.len() > 1 && lower.starts_with('0') {
        (8, &lower[1..])
    } else {
        (10, lower.as_str())
    };
    if digits.is_empty() || !digits.chars().all(|c| c.is_digit(radix)) {
        return None;
    }
    u64::from_str_radix(digits, radix).ok()
}

/// Return whether `s` matches go-yaml's float pattern
/// `^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$`.
fn yaml_style_float(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let digits = |i: &mut usize| {
        let start = *i;
        while *i < b.len() && b[*i].is_ascii_digit() {
            *i += 1;
        }
        *i - start
    };
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        if digits(&mut i) == 0 {
            return false;
        }
    } else {
        if digits(&mut i) == 0 {
            return false;
        }
        if i < b.len() && b[i] == b'.' {
            i += 1;
            digits(&mut i);
        }
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        if digits(&mut i) == 0 {
            return false;
        }
    }
    i == b.len()
}

/// Print `f` as yq prints a float: Go's shortest digits, in plain form
/// from 1e-6 up to 1e21 and in exponent form with at least two exponent
/// digits outside that range.
fn go_float_text(f: f64) -> String {
    if f == 0.0 {
        return if f.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    let sign = if f < 0.0 { "-" } else { "" };
    // Rust's `{:e}` prints the shortest digits that read back as `f`, as
    // Go's precision -1 does, for example "1.2345e-7".
    let sci = format!("{:e}", f.abs());
    let (mantissa, exp) = sci.split_once('e').expect("{:e} prints an exponent");
    let exp: i32 = exp.parse().expect("{:e} prints an integer exponent");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let abs = f.abs();
    if !(1e-6..1e21).contains(&abs) {
        let (head, tail) = digits.split_at(1);
        let dot = if tail.is_empty() { "" } else { "." };
        let esign = if exp < 0 { '-' } else { '+' };
        return format!("{sign}{head}{dot}{tail}e{esign}{:02}", exp.abs());
    }
    let n = digits.len() as i32;
    let body = if exp >= n - 1 {
        format!("{digits}{}", "0".repeat((exp - (n - 1)) as usize))
    } else if exp >= 0 {
        let (int, frac) = digits.split_at(exp as usize + 1);
        format!("{int}.{frac}")
    } else {
        format!("0.{}{digits}", "0".repeat((-exp - 1) as usize))
    };
    format!("{sign}{body}")
}

fn write_json(out: &mut String, node: &Node) -> Result<(), YamlError> {
    match node {
        Node::Null => out.push_str("null"),
        Node::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Node::Int(i) => {
            let _ = write!(out, "{i}");
        }
        Node::Float(f) => out.push_str(&go_float_text(*f)),
        Node::Str(s) => {
            out.push_str(&serde_json::to_string(s).map_err(|e| YamlError(e.to_string()))?)
        }
        Node::Seq(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json(out, item)?;
            }
            out.push(']');
        }
        Node::Map(entries) => {
            out.push('{');
            for (i, (k, v)) in entries.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(k).map_err(|e| YamlError(e.to_string()))?);
                out.push(':');
                write_json(out, v)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(scalar: &str) -> String {
        let json = to_json(&format!("a: {scalar}\n")).unwrap();
        json.strip_prefix(r#"[{"a":"#)
            .and_then(|s| s.strip_suffix("}]"))
            .unwrap_or_else(|| panic!("{json}"))
            .to_string()
    }

    /// Each pair is a scalar and the JSON yq 4.52.4 printed for it.
    #[test]
    fn scalars_print_as_yq_prints_them() {
        for (yaml, json) in [
            ("0755", "755"),
            ("0o755", "493"),
            ("0x1F", "31"),
            ("0x_1", "1"),
            ("1_000", "1000"),
            ("1__0", "10"),
            ("+1", "1"),
            ("+0", "0"),
            ("-0", "-0"),
            ("-00", "0"),
            ("007", "7"),
            ("-007", "-7"),
            ("08", "8"),
            ("-08", "-8"),
            ("09.5", "9.5"),
            ("1e3", "1000"),
            ("1E3", "1000"),
            ("1e+3", "1000"),
            ("1.0", "1"),
            ("100.0", "100"),
            ("1.", "1"),
            ("0.", "0"),
            (".5", "0.5"),
            ("+.5", "0.5"),
            ("-.5", "-0.5"),
            ("0.0", "0"),
            ("-0.0", "-0"),
            ("1.10", "1.1"),
            ("0.1", "0.1"),
            ("0.30000000000000004", "0.30000000000000004"),
            ("3.14159265358979323846", "3.141592653589793"),
            ("1.5e-3", "0.0015"),
            ("1e-5", "0.00001"),
            ("1.5e-6", "0.0000015"),
            ("1.0e-6", "0.000001"),
            ("9.99e-7", "9.99e-07"),
            ("1e-7", "1e-07"),
            ("-1e-7", "-1e-07"),
            ("1e20", "100000000000000000000"),
            ("123e18", "123000000000000000000"),
            ("999999999999999999999", "1e+21"),
            ("1e21", "1e+21"),
            ("1e3_0", "1e+30"),
            ("1.5e300", "1.5e+300"),
            ("1.5E+10", "15000000000"),
            ("123456.789e3", "123456789"),
            ("1_0.5", "10.5"),
            ("5e-324", "5e-324"),
            ("1.7976931348623157e308", "1.7976931348623157e+308"),
            ("9223372036854775807", "9223372036854775807"),
            ("-9223372036854775808", "-9223372036854775808"),
            ("123456789012345678", "123456789012345678"),
            ("1e400", r#""1e400""#),
            ("1:20", r#""1:20""#),
            ("2001-12-14", r#""2001-12-14""#),
            (
                "2001-12-14T21:59:43.10-05:00",
                r#""2001-12-14T21:59:43.10-05:00""#,
            ),
            ("._5", r#""._5""#),
            ("0o", r#""0o""#),
            ("0x", r#""0x""#),
            ("0xG", r#""0xG""#),
            ("0o8", r#""0o8""#),
            ("1e", r#""1e""#),
            (".", r#"".""#),
            ("+", r#""+""#),
            ("~", "null"),
            ("null", "null"),
            ("Null", "null"),
            ("NULL", "null"),
            ("", "null"),
            ("true", "true"),
            ("True", "true"),
            ("TRUE", "true"),
            ("False", "false"),
            ("yes", r#""yes""#),
            ("no", r#""no""#),
            ("on", r#""on""#),
            ("off", r#""off""#),
            ("y", r#""y""#),
            ("\"1\"", r#""1""#),
            ("'0755'", r#""0755""#),
            ("'it''s'", r#""it's""#),
            ("!!str 1", r#""1""#),
            ("!!str 1.0", r#""1.0""#),
            ("!!int \"5\"", "5"),
            ("!!int 0x10", "16"),
            ("!!int -0", "0"),
            ("!!float 1", "1"),
            ("!!float 1.0", "1"),
            ("!!float -0", "-0"),
            ("!!float 1_000.5", "1000.5"),
            ("!!bool yes", "true"),
            ("!!bool True", "true"),
            ("!!bool 1", "false"),
            ("!!null x", "null"),
            ("!!binary aGVsbG8=", r#""aGVsbG8=""#),
            ("!!timestamp 2001-12-14", r#""2001-12-14""#),
            ("!foo bar", r#""bar""#),
            ("!foo 5", "5"),
            ("!!str", r#""""#),
            ("\"multi\\nline\"", r#""multi\nline""#),
        ] {
            assert_eq!(one(yaml), json, "{yaml}");
        }
    }

    /// yq stops with an error on these, so no chart that rendered under
    /// yq contains one.
    #[test]
    fn scalars_yq_cannot_print_are_errors() {
        for yaml in [
            ".inf",
            "-.inf",
            ".Inf",
            ".nan",
            "12345678901234567890",
            "9223372036854775808",
            "0777777777777777777777",
            "0x8000000000000000",
            "0b101",
            "-0x10",
            "-0o7",
            "+0x10",
            "!!int 1.5",
            "!!int 1e3",
            "!!int abc",
            "!!float abc",
            "!!float 0x10",
        ] {
            assert!(to_json(&format!("a: {yaml}\n")).is_err(), "{yaml}");
        }
    }

    #[test]
    fn a_stream_becomes_an_array_of_documents() {
        let yaml = "---\n# Source: x\n---\na: 1\n---\n\n---\n~\n---\n- x\n...\n";
        let json: serde_json::Value = serde_json::from_str(&to_json(yaml).unwrap()).unwrap();
        let docs = json.as_array().unwrap();
        let non_null: Vec<_> = docs.iter().filter(|d| !d.is_null()).collect();
        assert_eq!(
            non_null,
            [&serde_json::json!({"a": 1}), &serde_json::json!(["x"])]
        );
        assert_eq!(to_json("").unwrap(), "[]");
    }

    /// Keys print as their text whatever their type, a repeated key prints
    /// twice, and anchors and merge keys expand as yq expands them.
    #[test]
    fn keys_aliases_and_merges() {
        let yaml = "\
b: &x {k: 1, m: 1}
c: *x
d: {<<: *x, z: 2}
e: {<<: *x, k: 3}
f: {k: 3, <<: *x}
1: one
0x10: hex
true: t
~: n
dup: 1
dup: 2
";
        assert_eq!(
            to_json(yaml).unwrap(),
            concat!(
                r#"[{"b":{"k":1,"m":1},"c":{"k":1,"m":1},"d":{"k":1,"m":1,"z":2},"#,
                r#""e":{"k":1,"m":1,"k":3},"f":{"k":1,"m":1},"#,
                r#""1":"one","0x10":"hex","true":"t","~":"n","dup":1,"dup":2}]"#
            )
        );
    }

    /// The charts this repository renders give the same JSON values as yq
    /// 4.52.4 gave for the same `helm template` output. The fixtures are
    /// Helm 4.3.1 renders: cilium with the values a test cluster passes,
    /// and the others with their own defaults or the repository's values.
    /// Numbers compare by type, so `1` and `1.0` differ.
    #[test]
    fn repository_charts_match_yq() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/helm-yaml");
        let read = |name: String| {
            let bytes = std::fs::read(dir.join(&name)).unwrap_or_else(|e| panic!("{name}: {e}"));
            String::from_utf8(zstd::decode_all(&bytes[..]).unwrap()).unwrap()
        };
        let documents = |json: &str| -> Vec<serde_json::Value> {
            let all: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
            all.into_iter().filter(|d| !d.is_null()).collect()
        };
        for chart in [
            "cilium",
            "home-assistant",
            "reflector",
            "smartctl-exporter",
            "test-app",
        ] {
            let ours = documents(&to_json(&read(format!("{chart}.yaml.zst"))).unwrap());
            let yq = documents(&read(format!("{chart}.yq.json.zst")));
            assert!(!yq.is_empty(), "{chart}");
            assert_eq!(ours, yq, "{chart}");
        }
    }

    #[test]
    fn invalid_yaml_is_an_error() {
        let err = to_json("a: [1, 2\n").unwrap_err();
        assert!(err.to_string().contains("not valid YAML"), "{err}");
    }
}
