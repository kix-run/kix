//! Errors the Kix library raises for a person to fix.
//!
//! `kix.fail` and `scope.fail` (`kix/lib/core/error.nix`) throw text for a
//! person, then one last line that starts with [`MARKER`] and holds the same
//! errors as JSON, each a [`LibraryRecord`]. [`parse`] reads that line from
//! Nix's stderr, and the [`std::fmt::Display`] of [`LibraryErrors`] shows
//! each error from its fields, without the stack trace.

use serde::Deserialize;

pub use super::library_record::LibraryRecord;

/// The start of the line that carries the errors, version 1 of the format.
pub const MARKER: &str = "kix-error/1 ";

/// The errors of one failed evaluation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryErrors {
    pub errors: Vec<LibraryRecord>,
    /// The cluster whose problem list this is, when the library named one.
    pub cluster: Option<String>,
    /// Nix's whole stderr, kept when the reader asked for `-v`.
    pub trace: Option<String>,
}

#[derive(Deserialize)]
struct Payload {
    errors: Vec<LibraryRecord>,
    #[serde(default)]
    cluster: Option<String>,
}

/// Return the errors in the marker line of `stderr`, or `None` when Nix's
/// error carries none.
///
/// Only the final `error:` block counts. The stack frames above it quote
/// source lines, and the library's own source contains the marker.
pub fn parse(stderr: &str) -> Option<LibraryErrors> {
    let lines: Vec<&str> = stderr.lines().collect();
    let last_error = lines
        .iter()
        .rposition(|l| l.trim_start().starts_with("error:"))?;
    let line = lines[last_error..]
        .iter()
        .rev()
        .find_map(|l| l.trim_start().strip_prefix(MARKER))?;
    let payload: Payload = serde_json::from_str(line).ok()?;
    if payload.errors.is_empty() {
        return None;
    }
    Some(LibraryErrors {
        errors: payload.errors,
        cluster: payload.cluster,
        trace: None,
    })
}

impl std::fmt::Display for LibraryErrors {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.errors.as_slice(), &self.cluster) {
            ([one], None) => write!(f, "{}", one.describe(""))?,
            (errors, cluster) => {
                let n = errors.len();
                let s = if n == 1 { "" } else { "s" };
                match cluster {
                    Some(c) => write!(f, "cluster '{c}' has {n} problem{s}:")?,
                    None => write!(f, "There are {n} problem{s}:")?,
                }
                for e in errors {
                    write!(f, "\n  - {}", e.describe("    "))?;
                }
            }
        }
        if let Some(trace) = &self.trace {
            write!(f, "\n\nNix's error and stack trace:\n{}", trace.trim_end())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frame of the trace that quotes `kix/lib/core/error.nix`, whose
    /// source holds the marker text.
    const QUOTING_FRAME: &str = r#"       … while calling 'render'
         at /nix/store/x-source/kix/lib/core/error.nix:90:5:
           89|     in
           90|     "${text}\nkix-error/1 ${builtins.toJSON payload}";
             |     ^
"#;

    fn stderr(message_lines: &[&str]) -> String {
        let mut s = format!("warning: Git tree '/p' is dirty\nerror:\n{QUOTING_FRAME}\n");
        for (i, line) in message_lines.iter().enumerate() {
            let prefix = if i == 0 { "error: " } else { "" };
            s.push_str(&format!("       {prefix}{line}\n"));
        }
        s
    }

    #[test]
    fn one_error_is_read_with_quotes_and_newlines() {
        let json = r#"{"errors":[{"id":"K9503","instance":"shop/db","package":"cnpg-database","message":"the \"password\" option was removed.\nIt kept it in plain text.","fix":"Set this line:\n  deps.password = ref.shop.db-login;","option":"password","dependency":"password","clusterOption":"cluster.domain"}]}"#;
        let text = stderr(&[
            "[K9503] shop/db (cnpg-database): the \"password\" option was removed.",
            "It kept it in plain text.",
            &format!("{MARKER}{json}"),
        ]);
        let errors = parse(&text).expect("a library error");
        assert_eq!(
            errors.errors,
            vec![LibraryRecord {
                id: Some("K9503".into()),
                instance: Some("shop/db".into()),
                package: Some("cnpg-database".into()),
                option: Some("password".into()),
                dependency: Some("password".into()),
                cluster_option: Some("cluster.domain".into()),
                message: "the \"password\" option was removed.\nIt kept it in plain text.".into(),
                fix: Some("Set this line:\n  deps.password = ref.shop.db-login;".into()),
                object: None,
            }]
        );
        assert_eq!(
            errors.to_string(),
            "[K9503] shop/db (cnpg-database): the \"password\" option was removed.\n\
             It kept it in plain text.\n\
             Option: password\n\
             Dependency: password\n\
             Cluster option: cluster.domain\n\
             Fix: Set this line:\n  deps.password = ref.shop.db-login;"
        );
    }

    #[test]
    fn a_problem_list_names_the_cluster_and_each_problem() {
        let json = r#"{"cluster":"prod","errors":[{"id":"K0001","instance":"shop/db","message":"m1","fix":"f1\nf2"},{"message":"m2","severity":"new field"}]}"#;
        let errors = parse(&stderr(&[
            "cluster 'prod' has 2 problems:",
            &format!("{MARKER}{json}"),
        ]))
        .expect("a library error");
        assert_eq!(errors.cluster.as_deref(), Some("prod"));
        assert_eq!(
            errors.to_string(),
            "cluster 'prod' has 2 problems:\n  - [K0001] shop/db: m1\n    Fix: f1\n    f2\n  - m2"
        );
    }

    #[test]
    fn the_marker_in_a_quoted_frame_is_not_an_error() {
        assert!(QUOTING_FRAME.contains(MARKER));
        assert_eq!(parse(&stderr(&["attribute 'x' missing"])), None);
        // A marker line in a frame above the final block, as an older
        // error the evaluation caught and rethrew would print it.
        let text = format!(
            "error:\n       … while evaluating\n         {MARKER}{{\"errors\":[{{\"message\":\"old\"}}]}}\n\n       error: boom\n"
        );
        assert_eq!(parse(&text), None);
    }

    #[test]
    fn a_marker_that_is_not_json_is_not_an_error() {
        assert_eq!(
            parse(&stderr(&["boom", &format!("{MARKER}{{not json")])),
            None
        );
        assert_eq!(
            parse(&stderr(&["boom", &format!("{MARKER}{{\"errors\":[]}}")])),
            None
        );
    }

    #[test]
    fn a_short_error_without_frames_is_read() {
        let text =
            format!("error: boom\n       {MARKER}{{\"errors\":[{{\"message\":\"boom\"}}]}}\n");
        assert_eq!(parse(&text).map(|e| e.to_string()).as_deref(), Some("boom"));
    }

    #[test]
    fn the_trace_follows_when_asked_for() {
        let mut errors = parse(&stderr(&[
            "boom",
            &format!("{MARKER}{{\"errors\":[{{\"message\":\"boom\"}}]}}"),
        ]))
        .unwrap();
        errors.trace = Some("error:\n  … frames\n".into());
        assert_eq!(
            errors.to_string(),
            "boom\n\nNix's error and stack trace:\nerror:\n  … frames"
        );
    }
}
