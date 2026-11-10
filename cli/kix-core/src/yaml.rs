//! YAML reading and writing shared by every Kix command.
//!
//! All YAML goes through these functions so that output style and the rules
//! for typing untagged scalars stay the same everywhere.

use serde::Serialize;
use serde::de::DeserializeOwned;

pub use serde_saphyr::{DeserializeError, SerializeError};

/// Return the reader options.
///
/// Untagged scalars follow the YAML 1.2 core schema, which is what Kix has
/// always read and what `kix build` writes. So `yes`, `on`, `0755`, and
/// `1_000` stay strings, and `.inf` or `.nan` read into a JSON value become
/// null. Duplicate keys are an error. Error messages are one line, without a
/// source snippet, because the snippet would name the input `<input>`
/// instead of the file.
///
/// The size limits admit any manifest up to the 10 MiB Kix reads from a
/// directory. Nesting stops at 64 levels, the library default. The deepest
/// common CRD schemas nest under 30, and deeper input overflows a 2 MiB
/// thread stack in a debug build. Alias expansion keeps the library's cap
/// of one million replayed events.
pub fn read_options() -> serde_saphyr::Options {
    let mut budget = serde_saphyr::Budget::default();
    budget.max_events = 16 * 1024 * 1024;
    budget.max_nodes = 16 * 1024 * 1024;
    budget.enforce_alias_anchor_ratio = false;
    let mut options = serde_saphyr::Options::default();
    options.budget = Some(budget);
    options.strict_booleans = true;
    options.leading_zero_numbers_as_strings = true;
    options.underscored_numbers_as_strings = true;
    options.non_finite_float_policy = serde_saphyr::NonFiniteFloatPolicy::PassThrough;
    options.duplicate_keys = serde_saphyr::DuplicateKeyPolicy::Error;
    options.with_snippet = false;
    options
}

/// Return the writer options.
///
/// Long single-line strings stay on one line instead of being folded with
/// `>`, so a value can be found with `grep` in the output. Strings that YAML
/// 1.1 readers would take for a boolean, number, or null are quoted.
fn write_options() -> serde_saphyr::SerializerOptions {
    let mut options = serde_saphyr::SerializerOptions::default();
    options.folded_wrap_chars = usize::MAX;
    options.min_fold_chars = usize::MAX;
    options
}

/// Serialize a value to a YAML document.
pub fn to_string<T: Serialize>(value: &T) -> Result<String, SerializeError> {
    serde_saphyr::to_string_with_options(value, write_options())
}

/// Parse one YAML document.
pub fn from_str<T: DeserializeOwned>(text: &str) -> Result<T, DeserializeError> {
    serde_saphyr::from_str_with_options(text, read_options())
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn untagged_scalars_follow_yaml_1_2() {
        let doc: Value = from_str(
            "a: yes\nb: on\nc: 0755\nd: 1_000\ne: .inf\nf: true\ng: 12\nh: 1.5\ni: ~\nj: 0x1F\n",
        )
        .unwrap();
        assert_eq!(
            doc,
            json!({
                "a": "yes", "b": "on", "c": "0755", "d": "1_000", "e": null,
                "f": true, "g": 12, "h": 1.5, "i": null, "j": 31,
            })
        );
    }

    #[test]
    fn nesting_up_to_64_levels_is_read() {
        let deep = format!("{}0{}", "[".repeat(60), "]".repeat(60));
        assert!(from_str::<Value>(&deep).is_ok());
        let deeper = format!("{}0{}", "[".repeat(70), "]".repeat(70));
        assert!(from_str::<Value>(&deeper).is_err());
    }

    #[test]
    fn many_aliases_of_one_anchor_are_read() {
        let text = format!("a: &a 1\nb: [{}]\n", vec!["*a"; 500].join(","));
        assert!(from_str::<Value>(&text).is_ok());
    }

    #[test]
    fn a_repeated_key_is_refused() {
        assert!(from_str::<Value>("a: 1\na: 2\n").is_err());
    }

    #[test]
    fn strings_that_look_like_other_types_are_quoted() {
        let value = json!({"a": "yes", "b": "123", "c": "true", "d": "null", "e": "", "f": "1.10"});
        let text = to_string(&value).unwrap();
        assert_eq!(from_str::<Value>(&text).unwrap(), value);
        assert_eq!(
            text,
            "a: \"yes\"\nb: \"123\"\nc: \"true\"\nd: \"null\"\ne: \"\"\nf: \"1.10\"\n"
        );
    }

    #[test]
    fn long_strings_stay_on_one_line_and_multiline_strings_use_a_block() {
        let long = "word ".repeat(40).trim_end().to_string();
        let value = json!({"long": long, "multi": "one\ntwo\n"});
        let text = to_string(&value).unwrap();
        assert_eq!(text, format!("long: {long}\nmulti: |\n  one\n  two\n"));
        assert_eq!(from_str::<Value>(&text).unwrap(), value);
    }
}
