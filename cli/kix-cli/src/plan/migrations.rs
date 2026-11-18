//! Text for stateful workload replacements (migration pairs), shared by
//! `kix deploy`, `kix plan`, and `kix diff`.

use std::fmt::Write;

use kix::cluster::migrate::MigrationPair;
use kix::plan::document::Migration;

use crate::commands::deploy::Command;

/// One replacement as the messages name it.
pub struct Replacement {
    pub slot: String,
    pub reason: String,
    pub source: String,
    pub target: String,
}

impl From<&MigrationPair> for Replacement {
    fn from(p: &MigrationPair) -> Self {
        Replacement {
            slot: p.slot.clone(),
            reason: p.reason.clone(),
            source: p.source.display_id(),
            target: p.target.display_id(),
        }
    }
}

impl From<&Migration> for Replacement {
    fn from(m: &Migration) -> Self {
        Replacement {
            slot: m.slot.clone(),
            reason: m.reason.clone(),
            source: m.source.clone(),
            target: m.target.clone(),
        }
    }
}

/// Return the replacements `pairs` describe.
pub fn of_pairs(pairs: &[MigrationPair]) -> Vec<Replacement> {
    pairs.iter().map(Replacement::from).collect()
}

/// Write the block that lists each replacement, four spaces in.
pub fn write_pairs(out: &mut String, pairs: &[Replacement]) {
    for p in pairs {
        let _ = writeln!(out, "    {} ({}):", p.slot, p.reason);
        let _ = writeln!(out, "      - {}", p.source);
        let _ = writeln!(out, "      + {}", p.target);
    }
}

/// How the old workload of a replacement fares on deploy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceFate {
    /// Kept on the cluster as an orphan (no `--prune`).
    Kept,
    /// Deleted after the apply because `--prune` is set.
    Pruned,
    /// Deleted after the apply because the operator always prunes.
    OperatorPrunes,
}

/// Return the text `command` prints when it stops on `pairs` because
/// `--accept-migrations` is not set. `fate` says what the run would do with
/// each old workload. A rollback's text starts with the id of the change
/// record that made a rollback stop here.
pub fn stop(cluster: &str, pairs: &[Replacement], fate: SourceFate, command: Command) -> String {
    let n = pairs.len();
    let noun = command.noun();
    let id = match command {
        Command::Deploy => "",
        Command::Rollback => "[K3354] ",
    };
    let mut out = String::new();
    match fate {
        SourceFate::OperatorPrunes => {
            let _ = writeln!(
                out,
                "{id}{noun} of '{cluster}' refused: cannot hand {n} stateful workload replacement(s) to the operator without `--accept-migrations`."
            );
        }
        _ => {
            let _ = writeln!(
                out,
                "{id}{noun} of '{cluster}' stopped: {n} stateful workload replacement(s) require `--accept-migrations`."
            );
        }
    }
    let _ = writeln!(out, "Nothing was applied to the cluster.");
    let _ = writeln!(out);
    let _ = writeln!(out, "  Stateful workload replacements ({n}):");
    write_pairs(&mut out, pairs);
    let _ = writeln!(out);
    let _ = writeln!(out, "  What happens on {}:", noun.to_lowercase());
    for p in pairs {
        let line = match fate {
            SourceFate::Kept => format!(
                "{} is absent from the new build; without `--prune`, it is kept on the cluster as an orphan.",
                p.source
            ),
            SourceFate::Pruned => format!(
                "Because `--prune` is set, {} will be deleted after the apply.",
                p.source
            ),
            SourceFate::OperatorPrunes => format!(
                "The operator always prunes, so {} will be deleted after the apply.",
                p.source
            ),
        };
        let _ = writeln!(out, "    - {line}");
        let _ = writeln!(
            out,
            "    - Kix does not copy data between stateful workloads. {} will see only data already present in its storage.",
            p.target
        );
    }
    let _ = writeln!(out);
    let _ = writeln!(out, "  Next:");
    let invocation = command.invocation();
    let run = noun.to_lowercase();
    let sources = pairs
        .iter()
        .map(|p| p.source.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    match fate {
        SourceFate::Kept => {
            let _ = writeln!(
                out,
                "    Prepare or migrate your data, then run the {run} with `--accept-migrations`:"
            );
            let _ = writeln!(out, "      {invocation} {cluster} --accept-migrations");
        }
        SourceFate::Pruned => {
            let _ = writeln!(
                out,
                "    Back up or migrate data from {sources} first, then run the {run} with `--accept-migrations`:"
            );
            let _ = writeln!(
                out,
                "      {invocation} {cluster} --prune --accept-migrations"
            );
        }
        SourceFate::OperatorPrunes => {
            let _ = writeln!(
                out,
                "    Back up or migrate data from {sources} first, then add `--accept-migrations`:"
            );
            let _ = writeln!(
                out,
                "      {invocation} {cluster} --operator --accept-migrations"
            );
        }
    }
    out
}

/// Return the text `kix deploy --accept-migrations` prints before it
/// continues.
pub fn accepted(pairs: &[Replacement], prune: bool) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "Stateful workload replacement accepted (`--accept-migrations`, {}):",
        pairs.len()
    );
    write_pairs(&mut out, pairs);
    for p in pairs {
        let fate = if prune {
            format!("{} will be deleted after the apply (`--prune`).", p.source)
        } else {
            format!("{} will be kept as an orphan (no `--prune`).", p.source)
        };
        let _ = writeln!(
            out,
            "  {fate} Kix does not copy data; {} sees only data already present in its storage.",
            p.target
        );
    }
    out
}

/// Return the text `kix plan` prints for `pairs`.
pub fn plan(pairs: &[Replacement], accepted: bool) -> String {
    let mut out = String::new();
    if accepted {
        let _ = writeln!(
            out,
            "Stateful workload replacements ({}, accepted with `--accept-migrations`):",
            pairs.len()
        );
    } else {
        let _ = writeln!(out, "Stateful workload replacements ({}):", pairs.len());
    }
    write_pairs(&mut out, pairs);
    for p in pairs {
        let _ = writeln!(
            out,
            "  Without `--prune`, {} is kept as an orphan; with `--prune` (or the operator), it is deleted after the apply.",
            p.source
        );
        let _ = writeln!(
            out,
            "  Kix does not copy data; {} sees only data already present in its storage.",
            p.target
        );
    }
    if !accepted {
        let _ = writeln!(
            out,
            "  `kix deploy` will stop unless `--accept-migrations` is passed."
        );
    }
    out
}

/// Return the text `kix diff` prints for `pairs`.
pub fn diff(pairs: &[Replacement]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "Stateful workload replacements ({}):", pairs.len());
    write_pairs(&mut out, pairs);
    for p in pairs {
        let _ = writeln!(
            out,
            "  Data migration is not automated: Kix does not copy data, and {} sees only data already present in its storage.",
            p.target
        );
    }
    let _ = writeln!(out, "  `kix deploy` requires `--accept-migrations`.");
    out
}

/// Return the Markdown `kix diff -o markdown` prints for `pairs`.
pub fn diff_markdown(pairs: &[Replacement]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "### Stateful workload replacements ({})", pairs.len());
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "> :warning: Data migration is not automated: Kix does not copy data, and workloads using the new storage see only data already present there. `kix deploy` requires `--accept-migrations`."
    );
    let _ = writeln!(out);
    let _ = writeln!(out, "```diff");
    for p in pairs {
        let _ = writeln!(out, "  {} ({}):", p.slot, p.reason);
        let _ = writeln!(out, "-   {}", p.source);
        let _ = writeln!(out, "+   {}", p.target);
    }
    let _ = writeln!(out, "```");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> Replacement {
        Replacement {
            slot: "data/postgres".into(),
            reason: "kind changed".into(),
            source: "StatefulSet/postgres@data".into(),
            target: "SGCluster/postgres@data".into(),
        }
    }

    /// A stop says nothing was applied, lists the pair, and gives the
    /// command with the flags the fate needs.
    #[test]
    fn a_stop_says_nothing_was_applied_and_names_the_flag() {
        let text = stop("prod", &[pair()], SourceFate::Pruned, Command::Deploy);
        assert!(
            text.contains("Nothing was applied to the cluster."),
            "{text}"
        );
        assert!(text.contains("    data/postgres (kind changed):\n      - StatefulSet/postgres@data\n      + SGCluster/postgres@data\n"), "{text}");
        assert!(
            text.contains("kix deploy prod --prune --accept-migrations"),
            "{text}"
        );
        let kept = stop("prod", &[pair()], SourceFate::Kept, Command::Deploy);
        assert!(kept.contains("kept on the cluster as an orphan"), "{kept}");
        let operator = stop(
            "prod",
            &[pair()],
            SourceFate::OperatorPrunes,
            Command::Deploy,
        );
        assert!(
            operator.starts_with("Deploy of 'prod' refused"),
            "{operator}"
        );
    }

    /// A rollback stops on the same migration and names its own command,
    /// with the id of the change that made it stop.
    #[test]
    fn a_rollback_stop_names_kix_rollback() {
        let text = stop("prod", &[pair()], SourceFate::Kept, Command::Rollback);
        assert!(
            text.starts_with("[K3354] Rollback of 'prod' stopped"),
            "{text}"
        );
        assert!(
            text.contains("kix rollback prod --accept-migrations"),
            "{text}"
        );
        assert!(!text.contains("kix deploy"), "{text}");
    }
}
