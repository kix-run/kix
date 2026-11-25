//! The text output of `kix status`.

use std::fmt::Write;

use super::document::{
    ClusterStatus, Drift, DriftState, LeavingStatus, ObjectsFrom, PackageStatus, Present, Problem,
    ResourceStatus, StatusDocument, Summary,
};
use crate::output;

/// How much the text output shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Detail {
    /// Only the objects with a problem (`-q`).
    Problems,
    /// A line for each package, then the objects with a problem.
    Packages,
    /// A line for each object (`-v`).
    Everything,
}

/// Render `doc`. `age` turns an RFC 3339 time into how long ago it was.
pub fn render(doc: &StatusDocument, detail: Detail, age: &dyn Fn(&str) -> String) -> String {
    let mut out = String::new();
    for (i, cluster) in doc.clusters.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        render_cluster(&mut out, doc, cluster, detail, age);
    }
    if detail != Detail::Problems {
        if doc.clusters.len() > 1 {
            let _ = writeln!(out, "\nAll clusters: {}", summary_line(&doc.summary));
        }
        if !doc.unreadable.is_empty() {
            let _ = writeln!(
                out,
                "\n{}",
                output::dim(&format!(
                    "This account may not list {}, so Kix did not check objects of those kinds.",
                    doc.unreadable.join(", ")
                ))
            );
        }
    }
    out.trim().to_string()
}

fn render_cluster(
    out: &mut String,
    doc: &StatusDocument,
    c: &ClusterStatus,
    detail: Detail,
    age: &dyn Fn(&str) -> String,
) {
    if detail != Detail::Problems {
        let mut header = format!("Cluster {}", output::bold(&c.cluster));
        if let Some(version) = &doc.kubernetes.version {
            let _ = write!(header, " on Kubernetes {version}");
        }
        match (&doc.kubernetes.context, &doc.kubernetes.server) {
            (Some(context), Some(server)) => {
                let _ = write!(header, " (context {context}, {server})");
            }
            (Some(context), None) => {
                let _ = write!(header, " (context {context})");
            }
            (None, Some(server)) => {
                let _ = write!(header, " ({server})");
            }
            (None, None) => {}
        }
        let _ = writeln!(out, "{header}");
        if detail == Detail::Everything
            && let Some(uid) = &doc.kubernetes.uid
        {
            let _ = writeln!(out, "Kubernetes cluster ID: {uid}");
        }
        let when = c
            .deploy
            .deployed_at
            .as_deref()
            .map(|at| format!("  {}", age(at)))
            .unwrap_or_default();
        let _ = writeln!(
            out,
            "Last deploy: {}  {}{when}",
            c.deploy.name,
            phase(&c.deploy.phase)
        );
        if c.objects_from == ObjectsFrom::Unknown {
            let _ = writeln!(
                out,
                "\n{}",
                output::yellow(&format!(
                    "Kix cannot tell which objects this deploy made: its record lists none, \
                     and the record's own object is gone. Run `kix deploy {} --reconcile` \
                     to write a new record.",
                    c.cluster
                ))
            );
            return;
        }
        let _ = writeln!(out);
        let width = c
            .packages
            .iter()
            .map(|p| package_label(p).chars().count())
            .max()
            .unwrap_or(0);
        for p in &c.packages {
            let n = p.summary.resources;
            let _ = writeln!(
                out,
                "  {:<width$}  {n:>3} {:<9}  {}",
                package_label(p),
                if n == 1 { "resource" } else { "resources" },
                package_state(&p.summary),
            );
        }
    }

    let shown: Vec<(&PackageStatus, Vec<&ResourceStatus>)> = c
        .packages
        .iter()
        .map(|p| {
            let rows = p
                .resources
                .iter()
                .filter(|r| detail == Detail::Everything || !r.problems.is_empty())
                .collect();
            (p, rows)
        })
        .filter(|(_, rows): &(_, Vec<_>)| !rows.is_empty())
        .collect();
    if !shown.is_empty() {
        let width = shown
            .iter()
            .flat_map(|(_, rows)| rows.iter().map(|r| resource_label(r).chars().count()))
            .max()
            .unwrap_or(0);
        let _ = writeln!(out);
        for (p, rows) in shown {
            let mut title = package_label(p);
            if detail == Detail::Problems && doc.clusters.len() > 1 {
                title = format!("{} {title}", c.cluster);
            }
            let _ = writeln!(out, "{}", output::bold(&title));
            for r in rows {
                let _ = writeln!(
                    out,
                    "  {:<width$}  {}",
                    resource_label(r),
                    resource_state(r, age)
                );
            }
        }
    }

    if !c.leaving.is_empty() {
        let width = c
            .leaving
            .iter()
            .map(|l| leaving_label(l).chars().count())
            .max()
            .unwrap_or(0);
        let mut title = "Not in the current deploy, still being deleted".to_string();
        if detail == Detail::Problems && doc.clusters.len() > 1 {
            title = format!("{} {title}", c.cluster);
        }
        let _ = writeln!(out, "\n{}", output::bold(&title));
        for l in &c.leaving {
            let _ = writeln!(
                out,
                "  {:<width$}  {}",
                leaving_label(l),
                output::red(&deletion_state(&l.deleting_since, &l.finalizers, age)),
            );
        }
    }

    if detail != Detail::Problems {
        let _ = writeln!(out, "\n{}", summary_line(&c.summary));
        let s = &c.summary;
        if s.missing + s.changed > 0 {
            let _ = writeln!(out, "{}", next_step(c));
        }
        if s.deleting + s.leaving > 0 {
            let _ = writeln!(
                out,
                "Kubernetes keeps a deleting object until every finalizer on it is removed. \
                 If deletion is stuck on a finalizer, check that its controller is running."
            );
        }
    }
    for note in &c.notes {
        let _ = writeln!(out, "{}", output::yellow(note));
    }
}

/// Return the `Next:` line for a cluster with a missing or changed object.
///
/// A deploy stops on a field ownership conflict when another manager owns a
/// field it applies and Kix does not, so the line adds `--force-conflicts`
/// when a manager other than Kix owns such a field of a changed object. A
/// manager that shares all its fields with Kix changed none of them. A
/// replica count changed through `/scale` with no recorded owner needs only
/// `--reconcile`.
fn next_step(c: &ClusterStatus) -> String {
    let mut managers: Vec<&str> = c
        .packages
        .iter()
        .flat_map(|p| &p.resources)
        .filter(|r| r.problems.contains(&Problem::Changed))
        .filter_map(|r| r.drift.as_ref())
        .flat_map(|d| &d.foreign_owners)
        .filter(|o| !o.unshared_paths.is_empty())
        .map(|o| o.manager.as_str())
        .collect();
    managers.sort();
    managers.dedup();
    let cluster = &c.cluster;
    if managers.is_empty() {
        format!(
            "Next: run `kix deploy {cluster} --reconcile` to put back what is missing or changed. \
             `kix plan {cluster} --reconcile` shows what it would change first."
        )
    } else {
        format!(
            "Next: run `kix deploy {cluster} --reconcile --force-conflicts` to put back what is \
             missing or changed and take back the fields that {} {}. \
             `kix plan {cluster} --reconcile --force-conflicts` shows what it would change first.",
            and_list(&managers),
            if managers.len() == 1 { "owns" } else { "own" }
        )
    }
}

/// Join `items` with commas and a final "and".
fn and_list(items: &[&str]) -> String {
    match items {
        [] => String::new(),
        [one] => one.to_string(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

fn phase(phase: &str) -> String {
    match phase {
        "Active" => output::green(phase).into_owned(),
        "Degraded" => output::yellow(phase).into_owned(),
        "" => output::dim("no phase").into_owned(),
        _ => phase.to_string(),
    }
}

fn package_label(p: &PackageStatus) -> String {
    p.name
        .clone()
        .unwrap_or_else(|| "(cluster-level)".to_string())
}

/// Return a package's state: `ok`, or its counts, such as `1 changed, 1 not
/// checked`.
fn package_state(s: &Summary) -> String {
    let problems = problem_counts(s);
    let mut parts = Vec::new();
    if problems.is_empty() {
        if s.not_checked == 0 {
            return output::green("ok").into_owned();
        }
        if s.ok > 0 {
            parts.push(output::green(&format!("{} ok", s.ok)).into_owned());
        }
    } else {
        parts.push(output::red(&problems.join(", ")).into_owned());
    }
    if s.not_checked > 0 {
        parts.push(output::dim(&format!("{} not checked", s.not_checked)).into_owned());
    }
    parts.join(", ")
}

fn problem_counts(s: &Summary) -> Vec<String> {
    let mut parts = Vec::new();
    if s.changed > 0 {
        parts.push(format!("{} changed", s.changed));
    }
    if s.not_ready > 0 {
        parts.push(format!("{} not ready", s.not_ready));
    }
    if s.missing > 0 {
        parts.push(format!("{} missing", s.missing));
    }
    if s.deleting > 0 {
        parts.push(format!("{} being deleted", s.deleting));
    }
    parts
}

/// Return the closing line, such as `29 resources: 26 ok, 1 changed, 2 not
/// checked.`
fn summary_line(s: &Summary) -> String {
    let mut parts = vec![format!("{} ok", s.ok)];
    parts.extend(problem_counts(s));
    if s.not_checked > 0 {
        parts.push(format!("{} not checked", s.not_checked));
    }
    let mut line = format!(
        "{} {}: {}.",
        s.resources,
        if s.resources == 1 {
            "resource"
        } else {
            "resources"
        },
        parts.join(", ")
    );
    match s.leaving {
        0 => {}
        1 => line.push_str(" 1 object not in the current deploy is still being deleted."),
        n => line.push_str(&format!(
            " {n} objects not in the current deploy are still being deleted."
        )),
    }
    line
}

fn resource_label(r: &ResourceStatus) -> String {
    let kind = kix::manifest::types::qualified_kind(&r.group, &r.kind);
    match &r.namespace {
        Some(ns) => format!("{kind} {ns}/{}", r.name),
        None => format!("{kind} {}", r.name),
    }
}

fn leaving_label(l: &LeavingStatus) -> String {
    let kind = kix::manifest::types::qualified_kind(&l.group, &l.kind);
    match &l.namespace {
        Some(ns) => format!("{kind} {ns}/{}", l.name),
        None => format!("{kind} {}", l.name),
    }
}

/// Describe an unfinished delete: when it started and what it waits for.
fn deletion_state(since: &str, finalizers: &[String], age: &dyn Fn(&str) -> String) -> String {
    let started = format!("being deleted (started {})", age(since));
    if finalizers.is_empty() {
        started
    } else {
        format!("{started}, waiting for {}", finalizers.join(", "))
    }
}

fn resource_state(r: &ResourceStatus, age: &dyn Fn(&str) -> String) -> String {
    let mut parts: Vec<String> = Vec::new();
    for p in &r.problems {
        parts.push(match p {
            Problem::Missing if r.needed_by.is_empty() => output::red("missing").into_owned(),
            Problem::Missing => format!(
                "{}, needed by {}",
                output::red("missing"),
                r.needed_by.join(", ")
            ),
            Problem::Changed => output::red(&changed(r.drift.as_ref())).into_owned(),
            Problem::NotReady => match &r.not_ready_reason {
                Some(reason) => format!("{} ({reason})", output::red("not ready")),
                None => output::red("not ready").into_owned(),
            },
            Problem::Deleting => format!(
                "{}; run `kix deploy <cluster> --reconcile` to recreate it once deletion finishes",
                output::red(&deletion_state(
                    r.deleting_since.as_deref().unwrap_or_default(),
                    &r.finalizers,
                    age
                ))
            ),
        });
    }
    if parts.is_empty() {
        let not_checked = match (r.present, r.drift.as_ref().map(|d| d.verdict)) {
            (Present::Unknown, _) => Some("not checked: this account may not list its kind"),
            (Present::Ambiguous, _) => Some(
                "not checked: multiple API groups serve this kind, and this object's API group is not in the deploy record; run `kix deploy <cluster> --reconcile` to record it",
            ),
            (_, Some(DriftState::Unstamped)) => {
                Some("not checked for changes: no applied-hash stamp yet, the next deploy adds it")
            }
            (_, Some(DriftState::NoFieldset)) => {
                Some("not checked for changes: Kubernetes records no fields Kix owns")
            }
            _ => None,
        };
        return match (not_checked, r.present) {
            (Some(why), _) => output::dim(why).into_owned(),
            (None, Present::External) => output::dim("ok (imported)").into_owned(),
            (None, _) => output::green("ok").into_owned(),
        };
    }
    parts.join("; ")
}

/// Describe a changed object: who changed which fields, when Kubernetes
/// recorded it.
///
/// A field another manager shares with Kix still holds the value Kix
/// applied, so only unshared fields name the manager that changed them.
fn changed(drift: Option<&Drift>) -> String {
    let Some(drift) = drift else {
        return "changed since deploy".to_string();
    };
    if let Some(scale) = &drift.unrecorded_scale {
        return if scale.deployed == scale.live {
            format!(
                "changed since deploy (a write through /scale took {} from Kix, value still {})",
                scale.path, scale.live
            )
        } else {
            format!(
                "changed since deploy ({} from {} to {} through /scale)",
                scale.path, scale.deployed, scale.live
            )
        };
    }
    let fields: Vec<String> = drift
        .foreign_owners
        .iter()
        .flat_map(|o| {
            o.unshared_paths
                .iter()
                .map(move |p| format!("{p} by {}", o.manager))
        })
        .collect();
    const SHOWN: usize = 3;
    match fields.len() {
        0 => "changed since deploy".to_string(),
        n if n <= SHOWN => format!("changed since deploy ({})", fields.join(", ")),
        n => format!(
            "changed since deploy ({}, and {} more fields)",
            fields[..SHOWN].join(", "),
            n - SHOWN
        ),
    }
}
