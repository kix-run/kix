//! The text `kix upgrade` prints. The wording follows the approved output
//! design for the command, so change it there first.

use std::collections::BTreeMap;

use kix::changes::Kind;
use kix::version::Version;

use super::compare::{Change, ObjectChange};
use super::plan::Applying;

/// The width prose is wrapped to.
const WIDTH: usize = 76;

/// Join `items` with commas.
pub fn list<S: AsRef<str>>(items: &[S]) -> String {
    items
        .iter()
        .map(|s| s.as_ref())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Join `items` with commas and a final "and".
pub fn and_list<S: AsRef<str>>(items: &[S]) -> String {
    let items: Vec<&str> = items.iter().map(|s| s.as_ref()).collect();
    match items.as_slice() {
        [] => String::new(),
        [one] => one.to_string(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

/// Wrap `text` to [`WIDTH`]: the first line starts with `first`, and the
/// lines after it with `indent` spaces.
pub fn wrap(first: &str, indent: usize, text: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = first.to_string();
    let mut empty = first.trim().is_empty();
    for word in text.split_whitespace() {
        if !empty && line.len() + 1 + word.len() > WIDTH {
            lines.push(line);
            line = " ".repeat(indent);
            empty = true;
        }
        if !empty {
            line.push(' ');
        }
        line.push_str(word);
        empty = false;
    }
    lines.push(line);
    lines
}

/// Return the lines of one release note, indented by `indent`, wrapped, and
/// followed by what the reader must do about it.
pub fn note(a: &Applying, indent: usize, preview: bool) -> Vec<String> {
    let r = &a.record;
    let mut paren = a.release.release();
    if r.touches_data {
        paren.push_str(", moves stored data");
    }
    for cve in &r.cve {
        paren.push_str(&format!(", {cve}"));
    }
    let head = if r.packages.is_empty() {
        format!("[{}] ({paren}):", a.reference())
    } else {
        format!("[{}] {} ({paren}):", a.reference(), list(&r.packages))
    };
    let mut lines = wrap(
        &format!("{}{head}", gutter(indent, a.likely)),
        indent + 2,
        &r.body,
    );
    let more = " ".repeat(indent + 2);
    if r.kind == Kind::Security
        && let Some(workaround) = &r.workaround
    {
        lines.extend(wrap(
            &format!("{more}Without upgrading:"),
            indent + 2,
            workaround,
        ));
    }
    if preview && r.kind == Kind::Silent && r.touches_data {
        lines.push(format!(
            "{more}Requires `kix upgrade --acknowledge {}` before `kix deploy`.",
            a.reference()
        ));
    }
    for c in &r.cli {
        lines.push(format!("{more}Check scripts and CI for `{c}`."));
    }
    if r.required_stop {
        lines.push(format!(
            "{more}Every cluster must deploy Kix {} before upgrading further.",
            a.release.release()
        ));
    }
    lines
}

/// Return the indent of a note's first line, with a `*` in it when the
/// note is a likely match.
fn gutter(indent: usize, likely: bool) -> String {
    if likely && indent >= 2 {
        format!("{}* ", " ".repeat(indent - 2))
    } else {
        " ".repeat(indent)
    }
}

/// Return whether Kix lists `a` one by one: a breaking, security, or
/// upgrade note, or a release every cluster must deploy.
fn is_listed(a: &Applying) -> bool {
    a.record.required_stop
        || matches!(
            a.record.kind,
            Kind::Error | Kind::Silent | Kind::Note | Kind::Security
        )
}

/// The changes Kix lists one by one.
pub fn listed(applying: &[Applying]) -> Vec<&Applying> {
    applying.iter().filter(|a| is_listed(a)).collect()
}

/// Return the group a listed note is shown under. A required stop of a
/// minor kind is shown with the upgrade notes.
fn group(a: &Applying) -> Kind {
    match a.record.kind {
        Kind::Added | Kind::Changed | Kind::Fixed => Kind::Note,
        kind => kind,
    }
}

/// Return the legend for likely matches, or `None` when no listed note is
/// one. `clusters` is the number of clusters when Kix knows it.
pub fn legend(applying: &[Applying], clusters: Option<usize>) -> Option<String> {
    listed(applying)
        .iter()
        .any(|a| a.likely)
        .then(|| match clusters {
            Some(n) => format!(
                "  * may affect your {n} {} (package name matches an instance in use)",
                if n == 1 { "cluster" } else { "clusters" }
            ),
            None => {
                "  * may affect this project (package name matches an instance in use)".to_string()
            }
        })
}

/// Return the release notes grouped by what the reader must do, then the
/// count of the minor changes Kix does not list.
pub fn notes(applying: &[Applying], preview: bool, from: &Version, to: &Version) -> Vec<String> {
    let groups = [
        (
            Kind::Error,
            "Config changes required (will fail the build until updated):",
            "Config changes required:",
        ),
        (
            Kind::Silent,
            "Behavior & data changes (builds cleanly, requires review before deploy):",
            "Behavior & data changes:",
        ),
        (
            Kind::Security,
            "Security fixes (builds cleanly, recommended for this upgrade):",
            "Security fixes:",
        ),
        (Kind::Note, "Notes:", "Notes:"),
    ];
    let mut lines = Vec::new();
    for (kind, in_preview, in_run) in groups {
        let of: Vec<&Applying> = listed(applying)
            .into_iter()
            .filter(|a| group(a) == kind)
            .collect();
        if of.is_empty() {
            continue;
        }
        if preview && !lines.is_empty() {
            lines.push(String::new());
        }
        lines.push(format!("  {}", if preview { in_preview } else { in_run }));
        for a in of {
            lines.extend(note(a, 4, preview));
        }
    }
    let minor = applying.len() - listed(applying).len();
    if minor > 0 {
        if !lines.is_empty() {
            lines.push(String::new());
        }
        let (from, to) = (from.release(), to.release());
        lines.push(if minor == 1 {
            format!(
                "  1 minor feature or bugfix change between {from} and {to} is not shown (see CHANGELOG.md)."
            )
        } else {
            format!(
                "  {minor} minor feature and bugfix changes between {from} and {to} are not shown (see CHANGELOG.md)."
            )
        });
    }
    lines
}

/// Return the preview's paragraph about releases with no release notes.
pub fn without_notes_paragraph(versions: &[String]) -> Vec<String> {
    let text = match versions {
        [one] => format!(
            "Release {one} predated structured release notes, so Kix cannot check which changes affect this project. Read CHANGELOG.md for {one} before upgrading."
        ),
        _ => format!(
            "Releases {} through {} predated structured release notes, so Kix cannot check which changes affect this project. Read CHANGELOG.md for {} before upgrading.",
            versions.first().map(String::as_str).unwrap_or_default(),
            versions.last().map(String::as_str).unwrap_or_default(),
            and_list(versions)
        ),
    };
    wrap("", 0, &text)
}

/// Return the run's line about releases with no release notes, printed on
/// the first run of an upgrade only.
pub fn without_notes_line(versions: &[String]) -> String {
    match versions {
        [one] => format!("Note: Kix {one} has no release notes; see CHANGELOG.md."),
        _ => format!(
            "Note: Kix {} through {} have no release notes; see CHANGELOG.md.",
            versions.first().map(String::as_str).unwrap_or_default(),
            versions.last().map(String::as_str).unwrap_or_default()
        ),
    }
}

/// What a build phase line says about the clusters that failed.
pub enum Failed<'a> {
    /// The first try of the target: only the names.
    Names(&'a [String]),
    /// A step or the baseline: how many of how many failed.
    Count(&'a [String], usize),
}

/// Return the build phase line.
pub fn build_line(
    count: usize,
    version: &Version,
    current: bool,
    names: Option<&[String]>,
    failed: Option<Failed>,
) -> String {
    let clusters = if count == 1 { "cluster" } else { "clusters" };
    let mut line = format!(
        "Building {count} {clusters} with {}Kix {}",
        if current { "current " } else { "" },
        version.release()
    );
    if let Some(names) = names {
        line.push_str(&format!(" ({})", list(names)));
    }
    line.push_str("... ");
    match failed {
        None => line.push_str("ok"),
        Some(Failed::Names(names)) => line.push_str(&format!("failed ({})", list(names))),
        Some(Failed::Count(names, total)) => line.push_str(&format!(
            "failed ({} of {total} failed: {})",
            names.len(),
            list(names)
        )),
    }
    line
}

/// Return the useful end of a failed build's output: from the last line
/// that starts with `error:`, once miette's `│` gutter is removed, to the
/// end. Without such a line, return the last 15 lines.
pub fn excerpt(output: &str) -> Vec<String> {
    let clean: Vec<String> = output
        .lines()
        .map(|l| {
            let t = l.trim_start();
            match t.strip_prefix('│') {
                Some(rest) => rest.strip_prefix(' ').unwrap_or(rest).to_string(),
                None => l.to_string(),
            }
        })
        .collect();
    let start = clean
        .iter()
        .rposition(|l| l.trim_start().starts_with("error:"))
        .unwrap_or_else(|| clean.len().saturating_sub(15));
    let mut out: Vec<String> = clean[start..]
        .iter()
        .map(|l| l.trim_end().to_string())
        .collect();
    if let Some(first) = out.first_mut() {
        *first = first.trim_start().to_string();
    }
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    out
}

/// Return the label a sensitive object is reviewed under.
fn review_label(c: &ObjectChange) -> String {
    let kind = c.id.split('/').next().unwrap_or_default();
    if matches!(kind, "Ingress" | "Gateway") {
        format!("{kind} TLS")
    } else {
        kind.to_string()
    }
}

/// Return a manifest change line, such as `~ Deployment/web@shop (web)`.
pub fn change_line(c: &ObjectChange) -> String {
    let sign = match c.change {
        Change::Added => '+',
        Change::Changed => '~',
        Change::Removed => '-',
    };
    let mut line = format!("{sign} {}", c.id);
    if let Some(p) = &c.package {
        line.push_str(&format!(" ({p})"));
    }
    if c.sensitive {
        line.push_str(&format!(" [review: {}]", review_label(c)));
    }
    line
}

/// Return the lines for one cluster's changes, in the order added,
/// changed, removed.
pub fn change_lines(changes: &[ObjectChange]) -> Vec<String> {
    let mut lines = Vec::new();
    for change in [Change::Added, Change::Changed, Change::Removed] {
        lines.extend(
            changes
                .iter()
                .filter(|c| c.change == change)
                .map(change_line),
        );
    }
    lines
}

fn plural(kind: &str) -> String {
    if kind.ends_with("TLS") {
        kind.to_string()
    } else if let Some(stem) = kind.strip_suffix('y') {
        format!("{stem}ies")
    } else if kind.ends_with('s') {
        format!("{kind}es")
    } else {
        format!("{kind}s")
    }
}

fn in_clusters(clusters: &[String]) -> String {
    if clusters.len() == 1 {
        format!("cluster {}", clusters[0])
    } else {
        format!("clusters {}", list(clusters))
    }
}

/// The changes the review list names.
#[derive(Default)]
pub struct Review {
    /// Sensitive objects, by label and the ids of the objects, with the
    /// clusters they changed in.
    pub sensitive: BTreeMap<(String, Vec<String>), Vec<String>>,
    /// How many objects changed, over every cluster.
    pub changed: usize,
    /// The clusters any object changed in.
    pub changed_clusters: Vec<String>,
}

impl Review {
    /// Add one cluster's changes.
    pub fn add(&mut self, cluster: &str, changes: &[ObjectChange]) {
        let mut by_label: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for c in changes.iter().filter(|c| c.sensitive) {
            by_label
                .entry(review_label(c))
                .or_default()
                .push(c.id.clone());
        }
        for (label, ids) in by_label {
            self.sensitive
                .entry((label, ids))
                .or_default()
                .push(cluster.to_string());
        }
        if !changes.is_empty() {
            self.changed += changes.len();
            self.changed_clusters.push(cluster.to_string());
        }
    }

    /// Return the review items for sensitive and changed objects.
    pub fn items(&self) -> Vec<Vec<String>> {
        let mut items = Vec::new();
        for ((label, ids), clusters) in &self.sensitive {
            let what = if ids.len() == 1 {
                format!("1 {label}")
            } else {
                format!("{} {}", ids.len(), plural(label))
            };
            items.push(wrap_item(&format!(
                "{what} changed in {} ({}).",
                in_clusters(clusters),
                list(ids)
            )));
        }
        if self.changed > 0 {
            let what = if self.changed == 1 {
                "1 object".to_string()
            } else {
                format!("{} objects", self.changed)
            };
            let command = match self.changed_clusters.as_slice() {
                [one] => format!("kix plan {one}"),
                _ => "kix plan <cluster>".to_string(),
            };
            items.push(wrap_item(&format!(
                "{what} changed in {}; read the changes above, or run `{command}`, before you deploy.",
                in_clusters(&self.changed_clusters)
            )));
        }
        items
    }
}

/// Mark the lines of one review item; [`numbered`] adds the number.
fn wrap_item(text: &str) -> Vec<String> {
    wrap("", 5, text)
}

/// Return review items as a numbered list.
pub fn numbered(items: &[Vec<String>]) -> Vec<String> {
    let mut out = Vec::new();
    for (n, item) in items.iter().enumerate() {
        for (i, line) in item.iter().enumerate() {
            if i == 0 {
                out.push(format!("  {}. {line}", n + 1));
            } else {
                out.push(line.clone());
            }
        }
    }
    out
}

/// Return the review item for a change with no build error that keeps
/// stored data as it is.
pub fn silent_item(a: &Applying) -> Vec<String> {
    let text = if a.record.packages.is_empty() {
        format!(
            "[{}] changes runtime behavior; review the release note above before deploying.",
            a.reference()
        )
    } else {
        format!(
            "[{}] changes runtime behavior in {}; review the release note above before deploying.",
            a.reference(),
            list(&a.record.packages)
        )
    };
    wrap_item(&text)
}

/// Return the review item for a change that moves stored data.
pub fn data_item(a: &Applying) -> Vec<String> {
    let first = if a.record.packages.is_empty() {
        format!(
            "[{}] moves stored data. Once you are ready for the",
            a.reference()
        )
    } else {
        format!(
            "[{}] moves stored data in {}. Once you are ready for the",
            a.reference(),
            list(&a.record.packages)
        )
    };
    vec![
        first,
        "     migration, unblock deploy with:".to_string(),
        format!("       kix upgrade --acknowledge {}", a.reference()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excerpt_keeps_the_last_error_and_drops_the_gutter() {
        let output = "warning: Git tree is dirty\nwarning: x\nError:   × failed to build cluster\n  │ error: The option `a` does not exist.\n  │        Did you mean `b`?\n  │ \n";
        assert_eq!(
            excerpt(output),
            [
                "error: The option `a` does not exist.",
                "       Did you mean `b`?"
            ]
        );
        let plain: String = (1..=20).map(|n| format!("line {n}\n")).collect();
        let got = excerpt(&plain);
        assert_eq!(got.len(), 15);
        assert_eq!(got[0], "line 6");
    }

    #[test]
    fn lists_and_wrapping() {
        assert_eq!(and_list(&["a"]), "a");
        assert_eq!(and_list(&["a", "b"]), "a and b");
        assert_eq!(and_list(&["a", "b", "c"]), "a, b, and c");
        let lines = wrap("  [K1] x (0.1.0):", 4, &"word ".repeat(30));
        assert!(lines.iter().all(|l| l.len() <= WIDTH), "{lines:?}");
        assert!(lines[1].starts_with("    word"));
        assert_eq!(plural("NetworkPolicy"), "NetworkPolicies");
        assert_eq!(plural("Secret"), "Secrets");
        assert_eq!(plural("Ingress TLS"), "Ingress TLS");
    }

    #[test]
    fn build_lines_follow_the_design() {
        let v: Version = "0.10.0".parse().unwrap();
        let names = vec!["ja1".to_string(), "li1".to_string()];
        assert_eq!(
            build_line(2, &v, true, Some(&names), None),
            "Building 2 clusters with current Kix 0.10.0 (ja1, li1)... ok"
        );
        let failed = vec!["li1".to_string()];
        assert_eq!(
            build_line(2, &v, false, None, Some(Failed::Names(&failed))),
            "Building 2 clusters with Kix 0.10.0... failed (li1)"
        );
        assert_eq!(
            build_line(2, &v, false, None, Some(Failed::Count(&failed, 2))),
            "Building 2 clusters with Kix 0.10.0... failed (1 of 2 failed: li1)"
        );
    }
}
