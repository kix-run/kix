//! Colored formatting for structural diffs.

use similar::TextDiff;

use super::{DiffConfig, DiffKind, Difference};

/// Format a list of differences for terminal output.
///
/// If `color` is true, uses ANSI escape codes:
/// - Red for missing-in-B (only in A)
/// - Green for extra-in-B (only in B)
/// - Yellow for value/type mismatches
///
/// If `full_diff` is true, multi-line string values are shown as unified diffs.
pub fn format_diffs(
    diffs: &[Difference],
    config: &DiffConfig,
    color: bool,
    full_diff: bool,
) -> String {
    if diffs.is_empty() {
        return String::new();
    }
    diffs
        .iter()
        .map(|d| format_one(d, config, color, full_diff))
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_one(d: &Difference, config: &DiffConfig, color: bool, full_diff: bool) -> String {
    if color {
        format_colored(d, config, full_diff)
    } else {
        format_plain(d, config, full_diff)
    }
}

fn format_plain(d: &Difference, config: &DiffConfig, full_diff: bool) -> String {
    match d.kind {
        DiffKind::MissingInB => {
            format!("  - {}: {}", d.path, compact(d.a_value.as_ref()))
        }
        DiffKind::ExtraInB => {
            format!("  + {}: {}", d.path, compact(d.b_value.as_ref()))
        }
        DiffKind::ValueMismatch => {
            if full_diff
                && let (Some(a), Some(b)) = (d.a_value.as_ref(), d.b_value.as_ref())
                && let (Some(a_str), Some(b_str)) = (a.as_str(), b.as_str())
                && (a_str.contains('\n') || b_str.contains('\n'))
            {
                let diff_text =
                    multiline_diff(a_str, b_str, &config.a_label, &config.b_label, false);
                return format!("  ~ {}:\n{}", d.path, diff_text);
            }
            format!(
                "  ~ {}:\n      {}: {}\n      {}: {}",
                d.path,
                config.a_label,
                compact(d.a_value.as_ref()),
                config.b_label,
                compact(d.b_value.as_ref()),
            )
        }
        DiffKind::TypeMismatch => {
            format!(
                "  ! {}: type mismatch\n      {}: {} = {}\n      {}: {} = {}",
                d.path,
                config.a_label,
                json_type_name(d.a_value.as_ref()),
                compact(d.a_value.as_ref()),
                config.b_label,
                json_type_name(d.b_value.as_ref()),
                compact(d.b_value.as_ref()),
            )
        }
    }
}

fn format_colored(d: &Difference, config: &DiffConfig, full_diff: bool) -> String {
    match d.kind {
        DiffKind::MissingInB => {
            format!(
                "  {RED}{BOLD}-{RESET} {DIM}{path}:{RESET} {RED}{val}{RESET}",
                path = d.path,
                val = compact(d.a_value.as_ref()),
            )
        }
        DiffKind::ExtraInB => {
            format!(
                "  {GREEN}{BOLD}+{RESET} {DIM}{path}:{RESET} {GREEN}{val}{RESET}",
                path = d.path,
                val = compact(d.b_value.as_ref()),
            )
        }
        DiffKind::ValueMismatch => {
            if full_diff
                && let (Some(a), Some(b)) = (d.a_value.as_ref(), d.b_value.as_ref())
                && let (Some(a_str), Some(b_str)) = (a.as_str(), b.as_str())
                && (a_str.contains('\n') || b_str.contains('\n'))
            {
                let diff_text =
                    multiline_diff(a_str, b_str, &config.a_label, &config.b_label, true);
                return format!(
                    "  {YELLOW}{BOLD}~{RESET} {DIM}{path}:{RESET}\n{diff_text}",
                    path = d.path,
                );
            }
            format!(
                "  {YELLOW}{BOLD}~{RESET} {DIM}{path}:{RESET}\n      {RED}{a_label}: {a_val}{RESET}\n      {GREEN}{b_label}: {b_val}{RESET}",
                path = d.path,
                a_label = config.a_label,
                a_val = compact(d.a_value.as_ref()),
                b_label = config.b_label,
                b_val = compact(d.b_value.as_ref()),
            )
        }
        DiffKind::TypeMismatch => {
            format!(
                "  {CYAN}{BOLD}!{RESET} {DIM}{path}:{RESET} type mismatch\n      {RED}{a_label}: {a_type} = {a_val}{RESET}\n      {GREEN}{b_label}: {b_type} = {b_val}{RESET}",
                path = d.path,
                a_label = config.a_label,
                a_type = json_type_name(d.a_value.as_ref()),
                a_val = compact(d.a_value.as_ref()),
                b_label = config.b_label,
                b_type = json_type_name(d.b_value.as_ref()),
                b_val = compact(d.b_value.as_ref()),
            )
        }
    }
}

/// Compact representation of a JSON value for diff output.
fn compact(value: Option<&serde_json::Value>) -> String {
    const MAX_LEN: usize = 120;

    let Some(value) = value else {
        return "null".to_string();
    };

    match value {
        serde_json::Value::Null => "null".to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => {
            if s.len() <= MAX_LEN && !s.contains('\n') {
                format!("{s:?}")
            } else {
                let first_line = s.lines().next().unwrap_or("");
                let line_count = s.lines().count();
                let truncated = if first_line.len() > 80 {
                    &first_line[..80]
                } else {
                    first_line
                };
                format!("{:?}", format!("{truncated}... ({line_count} lines)"))
            }
        }
        _ => {
            let r = value.to_string();
            if r.len() <= MAX_LEN {
                r
            } else {
                format!("{}...", &r[..MAX_LEN - 3])
            }
        }
    }
}

fn json_type_name(value: Option<&serde_json::Value>) -> &'static str {
    match value {
        None => "null",
        Some(serde_json::Value::Null) => "null",
        Some(serde_json::Value::Bool(_)) => "bool",
        Some(serde_json::Value::Number(_)) => "number",
        Some(serde_json::Value::String(_)) => "string",
        Some(serde_json::Value::Array(_)) => "array",
        Some(serde_json::Value::Object(_)) => "object",
    }
}

/// Generate a unified diff for multi-line string values using the `similar` crate.
fn multiline_diff(a: &str, b: &str, a_label: &str, b_label: &str, color: bool) -> String {
    let diff = TextDiff::from_lines(a, b);
    let mut result = Vec::new();
    let indent = "      ";

    let mut unified = diff.unified_diff();
    let header = unified.header(a_label, b_label).to_string();

    for line in header.lines() {
        if color {
            if line.starts_with("---") || line.starts_with("+++") {
                result.push(format!("{indent}{BOLD}{line}{RESET}"));
            } else if line.starts_with('-') {
                result.push(format!("{indent}{RED}{line}{RESET}"));
            } else if line.starts_with('+') {
                result.push(format!("{indent}{GREEN}{line}{RESET}"));
            } else if line.starts_with("@@") {
                result.push(format!("{indent}{CYAN}{line}{RESET}"));
            } else {
                result.push(format!("{indent}{line}"));
            }
        } else {
            result.push(format!("{indent}{line}"));
        }
    }

    if result.is_empty() {
        return format!("{indent}(no differences)");
    }

    result.join("\n")
}

// ANSI constants
const RED: &str = "\x1b[31m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const CYAN: &str = "\x1b[36m";
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cfg() -> DiffConfig {
        DiffConfig::new("kix", "cluster")
    }

    #[test]
    fn format_missing_plain() {
        let d = Difference::missing_in_b("$.spec.replicas".into(), json!(3));
        let out = format_diffs(&[d], &cfg(), false, false);
        assert!(out.contains("- $.spec.replicas: 3"));
    }

    #[test]
    fn format_extra_plain() {
        let d = Difference::extra_in_b("$.status".into(), json!({"ready": true}));
        let out = format_diffs(&[d], &cfg(), false, false);
        assert!(out.contains("+ $.status:"));
    }

    #[test]
    fn format_value_mismatch_plain() {
        let d = Difference::value_mismatch("$.image".into(), json!("v1"), json!("v2"));
        let out = format_diffs(&[d], &cfg(), false, false);
        assert!(out.contains("~ $.image:"));
        assert!(out.contains("kix: \"v1\""));
        assert!(out.contains("cluster: \"v2\""));
    }

    #[test]
    fn format_type_mismatch_plain() {
        let d = Difference::type_mismatch("$.x".into(), json!("hello"), json!(42));
        let out = format_diffs(&[d], &cfg(), false, false);
        assert!(out.contains("! $.x: type mismatch"));
        assert!(out.contains("string"));
        assert!(out.contains("number"));
    }

    #[test]
    fn format_colored_has_ansi() {
        let d = Difference::missing_in_b("$.x".into(), json!(1));
        let out = format_diffs(&[d], &cfg(), true, false);
        assert!(out.contains("\x1b[31m")); // RED
    }

    #[test]
    fn format_empty_diffs() {
        let out = format_diffs(&[], &cfg(), false, false);
        assert!(out.is_empty());
    }

    #[test]
    fn multiline_diff_plain() {
        let d = Difference::value_mismatch(
            "$.data.config".into(),
            json!("line1\nline2\nline3"),
            json!("line1\nmodified\nline3"),
        );
        let out = format_diffs(&[d], &cfg(), false, true);
        assert!(out.contains("~ $.data.config:"));
        assert!(out.contains("-line2"));
        assert!(out.contains("+modified"));
    }

    #[test]
    fn compact_truncates_long_strings() {
        let long = "x".repeat(200);
        let result = compact(Some(&json!(long)));
        assert!(result.len() < 200);
    }

    #[test]
    fn compact_null() {
        assert_eq!(compact(None), "null");
        assert_eq!(compact(Some(&json!(null))), "null");
    }

    #[test]
    fn compact_bool() {
        assert_eq!(compact(Some(&json!(true))), "true");
    }

    #[test]
    fn compact_number() {
        assert_eq!(compact(Some(&json!(42))), "42");
    }

    #[test]
    fn compact_short_string() {
        assert_eq!(compact(Some(&json!("hello"))), "\"hello\"");
    }

    #[test]
    fn compact_object_short() {
        let val = json!({"a": 1});
        let result = compact(Some(&val));
        assert!(result.contains("\"a\""));
    }
}
