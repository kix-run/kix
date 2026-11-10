//! Values the API server treats as the same, so the differ does too.
//!
//! A built manifest and the live object it became can disagree on the wire
//! without disagreeing in meaning: the server omits empty lists and `null`,
//! fills documented defaults into structures it stores whole (a `fieldRef`,
//! a StatefulSet's `volumeClaimTemplates`), and writes resource quantities in
//! canonical string form. Each rule here pairs a spelling with the one it is
//! equal to. A value that differs from the default, or a quantity that
//! differs in amount, still shows.
//!
//! The rules match on the field path alone, not on the object's kind, so
//! `SERVER_DEFAULTS` also applies inside a custom resource with a field of
//! the same name (a `readinessProbe` an operator defaults differently), and
//! to the content match `StoreGraph::synthesize` uses to give a manifest its
//! reference path. Such a field set to the core default on one side and
//! absent on the other reads as equal.

use serde_json::Value;

/// Documented server defaults for fields the server may fill in or drop,
/// matched against the end of a diff path with list keys removed
/// (`$.spec.containers[web].readinessProbe.periodSeconds` is matched as
/// `$.spec.containers[].readinessProbe.periodSeconds`).
///
/// The server stores a `fieldRef` and each `volumeClaimTemplates` entry as one
/// atomic value, so the defaults it fills there appear in the kix-owned view
/// of the live object. `readOnly` and `initialDelaySeconds` are omitted from
/// the stored object when false or 0. A probe field a build sets to `null` is
/// stored with its default.
const SERVER_DEFAULTS: &[(&str, DefaultValue)] = &[
    (".fieldRef.apiVersion", DefaultValue::Str("v1")),
    (
        ".volumeClaimTemplates[].apiVersion",
        DefaultValue::Str("v1"),
    ),
    (
        ".volumeClaimTemplates[].kind",
        DefaultValue::Str("PersistentVolumeClaim"),
    ),
    (
        ".volumeClaimTemplates[].spec.volumeMode",
        DefaultValue::Str("Filesystem"),
    ),
    (
        ".volumeClaimTemplates[].status",
        DefaultValue::PendingClaimStatus,
    ),
    (".volumeMounts[].readOnly", DefaultValue::Bool(false)),
    (".livenessProbe.initialDelaySeconds", DefaultValue::Int(0)),
    (".livenessProbe.timeoutSeconds", DefaultValue::Int(1)),
    (".livenessProbe.periodSeconds", DefaultValue::Int(10)),
    (".livenessProbe.successThreshold", DefaultValue::Int(1)),
    (".livenessProbe.failureThreshold", DefaultValue::Int(3)),
    (".readinessProbe.initialDelaySeconds", DefaultValue::Int(0)),
    (".readinessProbe.timeoutSeconds", DefaultValue::Int(1)),
    (".readinessProbe.periodSeconds", DefaultValue::Int(10)),
    (".readinessProbe.successThreshold", DefaultValue::Int(1)),
    (".readinessProbe.failureThreshold", DefaultValue::Int(3)),
    (".startupProbe.initialDelaySeconds", DefaultValue::Int(0)),
    (".startupProbe.timeoutSeconds", DefaultValue::Int(1)),
    (".startupProbe.periodSeconds", DefaultValue::Int(10)),
    (".startupProbe.successThreshold", DefaultValue::Int(1)),
    (".startupProbe.failureThreshold", DefaultValue::Int(3)),
];

/// A default in [`SERVER_DEFAULTS`]. A `const` table cannot hold a `Value`.
enum DefaultValue {
    Str(&'static str),
    Bool(bool),
    Int(i64),
    /// `{"phase": "Pending"}`, the status a claim template is stored with.
    PendingClaimStatus,
}

impl DefaultValue {
    fn matches(&self, v: &Value) -> bool {
        match self {
            DefaultValue::Str(s) => v.as_str() == Some(s),
            DefaultValue::Bool(b) => v.as_bool() == Some(*b),
            DefaultValue::Int(i) => v.as_i64() == Some(*i),
            DefaultValue::PendingClaimStatus => *v == serde_json::json!({"phase": "Pending"}),
        }
    }
}

/// Check whether `value` at `path` means the same as the field being absent: it
/// is `null`, an empty list, or the server default listed for the path.
///
/// An empty object is not included. `emptyDir: {}` and many custom
/// resource fields mean something different from an absent field, and the
/// server keeps such an object, so the live side has it too.
pub fn equivalent_to_unset(path: &str, value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Array(items) if items.is_empty() => true,
        _ => server_default_matches(path, value),
    }
}

fn server_default_matches(path: &str, value: &Value) -> bool {
    let unkeyed = strip_list_keys(path);
    SERVER_DEFAULTS
        .iter()
        .any(|(suffix, default)| unkeyed.ends_with(suffix) && default.matches(value))
}

/// Strip list keys from a path so `$.a[x].b[0].c` becomes `$.a[].b[].c`.
fn strip_list_keys(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    let mut depth = 0usize;
    for ch in path.chars() {
        match ch {
            '[' => {
                if depth == 0 {
                    out.push('[');
                }
                depth += 1;
            }
            ']' if depth > 0 => {
                depth -= 1;
                if depth == 0 {
                    out.push(']');
                }
            }
            _ if depth == 0 => out.push(ch),
            _ => {}
        }
    }
    out
}

/// Maps whose values are resource quantities: `resources.limits`,
/// `resources.requests`, and a ResourceQuota's `spec.hard`.
const QUANTITY_MAPS: &[&str] = &["limits", "requests", "hard"];

/// Fields that hold a single resource quantity.
const QUANTITY_FIELDS: &[&str] = &["sizeLimit"];

/// Check whether the member `key` of the object named `parent` holds a resource
/// quantity.
pub(crate) fn is_quantity_field(parent: &str, key: &str) -> bool {
    QUANTITY_MAPS.contains(&parent) || QUANTITY_FIELDS.contains(&key)
}

/// Check whether two values are the same resource quantity, such as `1` and `"1"`,
/// or `"500m"` and `0.5`. Returns false when either does not parse.
pub fn same_quantity(a: &Value, b: &Value) -> bool {
    match (quantity_nanos(a), quantity_nanos(b)) {
        (Some(x), Some(y)) => x == y,
        _ => false,
    }
}

/// Parse a Kubernetes quantity in units of 10^-9, rounded up as Kubernetes rounds
/// a quantity below one nano-unit. Returns `None` when the value is not a quantity or
/// the amount does not fit in an `i128`.
fn quantity_nanos(v: &Value) -> Option<i128> {
    let text = match v {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    parse_quantity(&text)
}

fn parse_quantity(s: &str) -> Option<i128> {
    let (negative, rest) = match s.as_bytes().first()? {
        b'-' => (true, &s[1..]),
        b'+' => (false, &s[1..]),
        _ => (false, s),
    };
    let number_end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(rest.len());
    let (number, suffix) = rest.split_at(number_end);
    let (int_part, frac_part) = number.split_once('.').unwrap_or((number, ""));
    if int_part.is_empty() && frac_part.is_empty() {
        return None;
    }
    let digits: String = format!("{int_part}{frac_part}");
    let mantissa: i128 = if digits.is_empty() {
        0
    } else {
        digits.parse().ok()?
    };

    let (exp10, exp2): (i32, u32) = match suffix {
        "" => (0, 0),
        "n" => (-9, 0),
        "u" => (-6, 0),
        "m" => (-3, 0),
        "k" => (3, 0),
        "M" => (6, 0),
        "G" => (9, 0),
        "T" => (12, 0),
        "P" => (15, 0),
        "E" => (18, 0),
        "Ki" => (0, 10),
        "Mi" => (0, 20),
        "Gi" => (0, 30),
        "Ti" => (0, 40),
        "Pi" => (0, 50),
        "Ei" => (0, 60),
        other => {
            let exp = other.strip_prefix(['e', 'E'])?;
            (exp.parse().ok()?, 0)
        }
    };

    // value = mantissa * 10^(exp10 - frac digits) * 2^exp2, in nanos.
    let scale = exp10 - i32::try_from(frac_part.len()).ok()? + 9;
    let mut value = mantissa.checked_mul(1i128.checked_shl(exp2)?)?;
    if scale >= 0 {
        value = value.checked_mul(10i128.checked_pow(u32::try_from(scale).ok()?)?)?;
    } else {
        let divisor = 10i128.checked_pow(u32::try_from(-scale).ok()?)?;
        value = (value + divisor - 1) / divisor;
    }
    Some(if negative { -value } else { value })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn null_and_empty_list_equal_an_absent_field() {
        assert!(equivalent_to_unset("$.metadata.annotations", &json!(null)));
        assert!(equivalent_to_unset("$.spec.containers[a].env", &json!([])));
        assert!(!equivalent_to_unset(
            "$.spec.volumes[a].emptyDir",
            &json!({})
        ));
        assert!(!equivalent_to_unset(
            "$.spec.containers[a].env",
            &json!([{"name": "X"}])
        ));
    }

    #[test]
    fn a_server_default_equals_an_absent_field_and_another_value_does_not() {
        let path = "$.spec.template.spec.containers[c].env[POD].valueFrom.fieldRef.apiVersion";
        assert!(equivalent_to_unset(path, &json!("v1")));
        assert!(!equivalent_to_unset(path, &json!("v2")));

        let probe = "$.spec.template.spec.containers[c].readinessProbe.failureThreshold";
        assert!(equivalent_to_unset(probe, &json!(3)));
        assert!(!equivalent_to_unset(probe, &json!(5)));

        let mount = "$.spec.containers[c].volumeMounts[/data].readOnly";
        assert!(equivalent_to_unset(mount, &json!(false)));
        assert!(!equivalent_to_unset(mount, &json!(true)));
    }

    #[test]
    fn list_keys_containing_dots_or_brackets_are_removed_whole() {
        assert_eq!(
            strip_list_keys("$.a[x.y].b[[0]].c"),
            "$.a[].b[].c".to_string()
        );
    }

    #[test]
    fn quantities_compare_by_amount() {
        assert!(same_quantity(&json!("1"), &json!(1)));
        assert!(same_quantity(&json!("500m"), &json!(0.5)));
        assert!(same_quantity(&json!("1Gi"), &json!("1073741824")));
        assert!(same_quantity(&json!("1k"), &json!("1e3")));
        assert!(same_quantity(&json!("100Mi"), &json!("104857600")));
        assert!(!same_quantity(&json!("1"), &json!("2")));
        assert!(!same_quantity(&json!("1Gi"), &json!("1G")));
        assert!(!same_quantity(&json!("lots"), &json!("lots")));
    }

    #[test]
    fn quantity_fields_are_named_by_their_map_or_key() {
        assert!(is_quantity_field("limits", "cpu"));
        assert!(is_quantity_field("requests", "nvidia.com/gpu"));
        assert!(is_quantity_field("emptyDir", "sizeLimit"));
        assert!(!is_quantity_field("spec", "replicas"));
    }
}
