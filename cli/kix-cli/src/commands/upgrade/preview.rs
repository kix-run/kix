//! Print what an upgrade would do, for `kix upgrade --dry-run`.

use std::collections::BTreeSet;
use std::path::Path;

use kix::changes::Kind;
use kix::installs;
use kix::version::Version;

use super::choose::tag_moved;
use super::out;
use super::plan::{self, Applying};
use super::route::Route;
use super::state::UpgradeState;
use super::subprocess::{clusters, packages_in_use};
use crate::cli::UpgradeArgs;

/// Print what the upgrade along `route` would do, changing nothing.
pub(super) fn dry_run(
    dir: &Path,
    resume: Option<&UpgradeState>,
    route: &Route,
    args: &UpgradeArgs,
    verbose: bool,
) {
    let from = &route.from;
    let from_kix = installs::installed()
        .into_iter()
        .find(|i| &i.version == from)
        .map(|i| i.bin());
    let (in_use, known) = match (resume, &from_kix) {
        (Some(s), _) => (
            saved_in_use(s),
            Known::of(s.packages_in_use.is_some(), None),
        ),
        // Kix X would evaluate the tag flake.nix now names, and Nix
        // would rewrite the lock, so a dry run does not ask it.
        (None, Some(_)) if tag_moved(dir) => (None, Known::Nothing),
        (None, Some(kix)) => {
            let in_use = packages_in_use(kix, from, dir);
            let count = clusters(kix, dir).ok().map(|c| c.len());
            let known = Known::of(in_use.is_some(), count);
            (in_use, known)
        }
        (None, None) => (None, Known::Nothing),
    };
    let applying = plan::applying(&route.records, from, &route.goal, in_use.as_ref());
    preview(&Preview {
        from,
        target: &route.target,
        steps: &route.steps,
        stop: route.stop.as_ref(),
        applying: &applying,
        known,
        without_notes: &route.without_notes,
        verbose,
        command: &match args.to.as_deref() {
            None | Some("latest") => "kix upgrade".to_string(),
            Some(text) => format!("kix upgrade --to {text}"),
        },
    });
}

/// Return the packages in use that a stopped run recorded.
pub(super) fn saved_in_use(s: &UpgradeState) -> Option<BTreeSet<String>> {
    s.packages_in_use
        .as_ref()
        .map(|p| p.iter().cloned().collect())
}

/// What a preview knows about the project.
#[derive(Clone, Copy)]
enum Known {
    /// The packages in use and how many clusters there are.
    Clusters(usize),
    /// The packages in use only.
    Packages,
    /// Neither, because the current Kix is not installed: every change in
    /// the range counts.
    Nothing,
    /// Neither, because the current Kix did not report the packages in use,
    /// such as a Kix too old to report package ids: every change in the
    /// range counts.
    Unreported,
}

impl Known {
    fn of(packages: bool, clusters: Option<usize>) -> Self {
        match (packages, clusters) {
            (true, Some(n)) => Known::Clusters(n),
            (true, None) => Known::Packages,
            (false, _) => Known::Unreported,
        }
    }
}

struct Preview<'a> {
    from: &'a Version,
    target: &'a Version,
    steps: &'a [Version],
    stop: Option<&'a (Version, Version)>,
    applying: &'a [Applying],
    known: Known,
    without_notes: &'a [String],
    verbose: bool,
    /// The command that runs this upgrade, as the person typed it without
    /// `--dry-run`.
    command: &'a str,
}

fn preview(p: &Preview) {
    let (from, target) = (p.from.release(), p.target.release());
    println!("Kix {from} -> {target} (dry run, no files changed)");
    if let Some((stop, until)) = p.stop {
        println!();
        println!(
            "Kix {} must be deployed to every cluster before upgrading further, so this upgrade will stop at Kix {} on the way to {target}.",
            stop.release(),
            until.release()
        );
    }
    if !p.without_notes.is_empty() {
        println!();
        for line in out::without_notes_paragraph(p.without_notes) {
            println!("{line}");
        }
    }
    let listed = out::listed(p.applying).len();
    let notes = out::notes(p.applying, true, p.from, p.target);
    if listed > 0 {
        let changes = if listed == 1 {
            "1 change".to_string()
        } else {
            format!("{listed} changes")
        };
        println!();
        println!("{changes} between {from} and {target}:");
        let legend = match p.known {
            Known::Clusters(n) => out::legend(p.applying, Some(n)),
            Known::Packages => out::legend(p.applying, None),
            Known::Nothing => Some(format!(
                "  (current Kix {from} is not installed, so notes are not marked)"
            )),
            Known::Unreported => Some(format!(
                "  (current Kix {from} did not report which packages your clusters use, so notes are not marked)"
            )),
        };
        if let Some(legend) = legend {
            println!("{legend}");
        }
        println!();
    } else if p.without_notes.is_empty() {
        println!();
        println!("No breaking, security, or upgrade notes between {from} and {target}.");
    }
    if !notes.is_empty() {
        if listed == 0 {
            println!();
        }
        for line in notes {
            println!("{line}");
        }
    }
    if p.verbose {
        let to_install = p
            .steps
            .iter()
            .filter(|v| !installs::installed().iter().any(|i| &i.version == *v))
            .count();
        let versions: Vec<String> = p.steps.iter().map(Version::release).collect();
        let versions = out::list(&versions);
        println!();
        match to_install {
            0 => println!("Stepping plan if direct jump fails: {versions} (all installed)."),
            1 => println!(
                "Stepping plan if direct jump fails: {versions} (1 version would be installed)."
            ),
            n => println!(
                "Stepping plan if direct jump fails: {versions} ({n} versions would be installed)."
            ),
        }
    }
    let config: Vec<String> = p
        .applying
        .iter()
        .filter(|a| a.record.kind == Kind::Error)
        .map(Applying::reference)
        .collect();
    println!();
    match config.as_slice() {
        [] => {}
        [one] => println!(
            "`kix upgrade` will stop at the step for [{one}] until you make the config change above."
        ),
        many => println!(
            "`kix upgrade` will stop for [{}] until you make the config changes above.",
            many.join("], [")
        ),
    }
    println!("Next: run `{}`.", p.command);
}
