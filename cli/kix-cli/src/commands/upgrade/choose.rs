//! Decide where `kix upgrade` goes, and end a run that does not go on.

use std::path::Path;

use kix::release::{self, Source};
use kix::version::Version;
use kix::version::policy::Requirement;
use miette::miette;

use super::halt::{Flow, refused};
use super::pin::edit_message;
use super::state::{self, UpgradeState};
use super::target::{self, Decision};
use super::{out, pin, plan};
use crate::cli::UpgradeArgs;
use crate::exit::Exit;

/// What [`choose`] found: the decision and what it read to make it.
pub(super) struct Chosen {
    pub(super) decision: Decision,
    /// The version `flake.lock` pins. A resumed run falls back to the
    /// version it started from when the lock pins no release.
    pub(super) pinned: Option<Version>,
    /// The release index, when the decision needed it.
    pub(super) index: Option<release::index::Index>,
    pub(super) source: Source,
    pub(super) system: String,
    pub(super) min_age: Option<u32>,
    pub(super) today: chrono::NaiveDate,
}

/// Decide the target of the upgrade, fetching the release index only when
/// the decision needs it.
pub(super) fn choose(
    dir: &Path,
    args: &UpgradeArgs,
    min_age: Option<u32>,
    resume: Option<&UpgradeState>,
) -> Flow<Chosen> {
    let resumed = match resume {
        Some(s) => Some(target::Resume {
            baseline: s
                .from
                .parse()
                .map_err(|_| miette!("{} names no version in `from`", state::FILE))?,
            requested: s.requested.clone(),
            goal: s.to.clone(),
        }),
        None => None,
    };
    let pinned = project_version(dir)?.or_else(|| resumed.as_ref().map(|r| r.baseline.clone()));
    let source = Source::from_env();
    let system = release::system().map_err(|e| miette!("{e}"))?;
    let today = chrono::Utc::now().date_naive();
    let ask = target::Ask {
        pinned: pinned.as_ref(),
        resume: resumed.as_ref(),
        to: args.to.as_deref(),
        system: &system,
        min_age,
        today,
    };
    let mut index = None;
    let mut decision = target::decide(&ask, None);
    if decision == Decision::NeedsReleases {
        let fetched = release::fetch_index(&source).map_err(|e| miette!("{e}"))?;
        decision = target::decide(&ask, Some(&fetched.releases));
        index = Some(fetched);
    }
    Ok(Chosen {
        decision,
        pinned,
        index,
        source,
        system,
        min_age,
        today,
    })
}

/// Refuse a new upgrade that would change files while the previous one
/// lists data migrations no one has acknowledged.
pub(super) fn check_acknowledged(previous: Option<&UpgradeState>, decision: &Decision) -> Flow<()> {
    if !matches!(decision, Decision::Proceed { .. } | Decision::PinOnly(_)) {
        return Ok(());
    }
    let Some(p) = previous else { return Ok(()) };
    let refs: Vec<&str> = p
        .unacknowledged()
        .iter()
        .map(|d| d.reference.as_str())
        .collect();
    if refs.is_empty() {
        return Ok(());
    }
    let migration = if refs.len() == 1 {
        "an unacknowledged data migration"
    } else {
        "unacknowledged data migrations"
    };
    Err(refused(format!(
        "Cannot start a new upgrade: the previous upgrade to Kix {} has {migration} ({}).\nNo project files were modified.\nNext: review {} in kix-upgrade.json, run `kix upgrade --acknowledge {}`, then run `kix upgrade` again.",
        p.to,
        out::list(&refs),
        out::list(&refs),
        refs.join(" ")
    )))
}

/// End a run whose decision is not to proceed: pin a project that pins no
/// release, say there is nothing to do, or refuse.
pub(super) fn conclude(dir: &Path, chosen: Chosen, dry_run: bool) -> Flow<Exit> {
    let Chosen {
        decision,
        index,
        system,
        min_age,
        today,
        ..
    } = chosen;
    let text = match decision {
        Decision::PinOnly(v) => {
            pin_only(dir, &v, dry_run)?;
            return Ok(Exit::Success);
        }
        Decision::NothingToDo { from, target, to } => {
            println!(
                "{}",
                nothing_to_upgrade(&from, &target, to.as_ref(), min_age)
            );
            return Ok(Exit::Success);
        }
        Decision::RefuseOlder { pinned, target } => older_message(&pinned, &target),
        Decision::ResumeNotNewer { from, target } => format!(
            "Cannot resume upgrade from Kix {from}: target Kix {target} is not newer than {from}.\nNo project files were modified.\nNext: pass a version newer than {from} with `--to`, or delete kix-upgrade.json to start a new upgrade.",
            from = from.release(),
            target = target.release()
        ),
        Decision::ResumeNeedsTo { goal } => format!(
            "Cannot resume upgrade to Kix {goal} without `--to`: an older version of Kix wrote kix-upgrade.json without saving the requested target.\nNo project files were modified.\nNext: run `kix upgrade --to <version>` with the version you asked for, or `kix upgrade --to latest` for the latest release."
        ),
        Decision::InvalidTo(text) => format!(
            "Invalid `--to` value `{text}`: expected a version (such as `0.12.1`), a minor series (such as `0.12`), or `latest`."
        ),
        Decision::NoRelease { to } => {
            let releases = index
                .as_ref()
                .map(|i| plan::usable(&i.releases, &system))
                .unwrap_or_default();
            no_release_message(
                &system,
                to.as_ref(),
                min_age,
                plan::newest_age(&releases, today),
            )
        }
        Decision::Proceed { .. } | Decision::NeedsReleases => {
            unreachable!("a run that proceeds, or has the index, is not concluded")
        }
    };
    Err(refused(text))
}

/// Return the refusal for a request no release on `system` matches.
/// `newest_age` is the age in days of the newest release, when known.
fn no_release_message(
    system: &str,
    to: Option<&Requirement>,
    min_age: Option<u32>,
    newest_age: Option<i64>,
) -> String {
    let newest_age = newest_age.map(|d| {
        format!(
            "newest release is {d} {} old",
            if d == 1 { "day" } else { "days" }
        )
    });
    match (to, min_age) {
        (Some(to), Some(days)) => format!(
            "No Kix release for {system} matches `--to {to}` and `min-age = \"{days}d\"` in kix.toml{}.\nNext: pass an exact version with `--to`, or lower `min-age` in kix.toml.",
            newest_age.map(|a| format!(" ({a})")).unwrap_or_default()
        ),
        (Some(to), None) => format!(
            "No Kix release for {system} matches `--to {to}`.\nNext: pass an available version or minor series with `--to`, or omit `--to` for the latest release."
        ),
        (None, Some(days)) => format!(
            "No Kix release for {system} is at least {days} days old (`min-age = \"{days}d\"` in kix.toml{}).\nNext: lower `min-age` in kix.toml, or pass an exact version with `--to`.",
            newest_age.map(|a| format!("; {a}")).unwrap_or_default()
        ),
        (None, None) => format!("No Kix release found for {system}."),
    }
}

/// Return the message that refuses to move the project from Kix `from` to
/// the older `target`.
fn older_message(from: &Version, target: &Version) -> String {
    format!(
        "Cannot move this project to Kix {target}: it is on Kix {from}, and `kix upgrade` only moves a project to a newer version.\nNo project files were modified.\nNext: to go back to Kix {target}, restore flake.nix and flake.lock from a commit that pinned it.",
        from = from.release(),
        target = target.release()
    )
}

/// Return the line that says the project on Kix `from` has nothing to
/// upgrade to. `target` is the release Kix chose, which is `from`, or older
/// only when `--to` is not given. `min_age` is `min-age` in kix.toml.
fn nothing_to_upgrade(
    from: &Version,
    target: &Version,
    to: Option<&Requirement>,
    min_age: Option<u32>,
) -> String {
    let (from, target) = (from.release(), target.release());
    match to {
        Some(Requirement::Exact(_)) => {
            return format!("Already on Kix {from}. Nothing to upgrade.");
        }
        Some(Requirement::Minor(..)) => {
            return format!("Already on Kix {from} (matches target {target}). Nothing to upgrade.");
        }
        None => {}
    }
    match (from == target, min_age) {
        (true, None) => format!("Already on the latest Kix release ({from}). Nothing to upgrade."),
        (true, Some(days)) => format!(
            "Already on Kix {from} (matches target {target} for `min-age = \"{days}d\"` in kix.toml). Nothing to upgrade."
        ),
        (false, None) => format!(
            "Kix {from} is newer than the latest Kix release ({target}). Nothing to upgrade."
        ),
        (false, Some(days)) => format!(
            "Kix {from} is newer than Kix {target}, the newest release at least {days} days old (`min-age = \"{days}d\"` in kix.toml). Nothing to upgrade."
        ),
    }
}

/// Set `flake.nix` in `dir` back to the tag `flake.lock` pins, when a person
/// moved it by hand.
pub(super) fn reset_moved_tag(dir: &Path) -> Flow<()> {
    let Err(kix::flake_lock::LockError::TagMoved { locked, asked }) =
        kix::flake_lock::project_kix(dir, &[])
    else {
        return Ok(());
    };
    if let Err(e) = kix::pin_library::reset_moved_tag(dir) {
        return Err(refused(format!(
            "{e}\nNext: make that change, then run `kix upgrade` again."
        )));
    }
    println!(
        "flake.nix asked for Kix {}, but flake.lock pins Kix {}. Kix set flake.nix back to {} to upgrade from there.",
        asked.release(),
        locked.release(),
        locked.release()
    );
    Ok(())
}

/// Return the version of Kix the project in `dir` uses, from the release
/// tag its `flake.lock` pins, or `None` when it pins none. When a person
/// moved the tag in `flake.nix` by hand, the lock's version is the one the
/// project is on.
fn project_version(dir: &Path) -> Flow<Option<Version>> {
    use kix::flake_lock::{Development, LockError, ProjectKix};
    match kix::flake_lock::project_kix(dir, &[]) {
        Ok(ProjectKix::Release(v)) => Ok(Some(v)),
        Ok(ProjectKix::Development(Development::OwnLibrary)) => Err(refused(
            "This project's kix.toml sets library = \"self\", so its flake provides the Kix library and it has no version of Kix to upgrade.",
        )),
        Ok(ProjectKix::Development(_)) => Ok(None),
        Err(LockError::TagMoved { locked, .. }) => Ok(Some(*locked)),
        Err(e @ (LockError::Unreadable { .. } | LockError::Setting(_))) => {
            Err(refused(format!("{e}\nNo project files were modified.")))
        }
        Err(_) => Ok(None),
    }
}

/// Return whether a person moved the tag in the `flake.nix` of `dir` after
/// `flake.lock` was written.
pub(super) fn tag_moved(dir: &Path) -> bool {
    matches!(
        kix::flake_lock::project_kix(dir, &[]),
        Err(kix::flake_lock::LockError::TagMoved { .. })
    )
}

/// Return whether git shows the file `rel` in `dir` changed since the last
/// commit. Moving a project from Kix 0.9 deletes the `kix` line of
/// `kix.toml`, so that file is committed with the pin.
fn modified(dir: &Path, rel: &str) -> bool {
    std::process::Command::new("git")
        .args(["status", "--porcelain", "--", rel])
        .current_dir(dir)
        .stderr(std::process::Stdio::null())
        .output()
        .is_ok_and(|o| o.status.success() && !o.stdout.is_empty())
}

/// Pin the project in `dir`, whose `flake.lock` pins no version of Kix, to
/// `version`. There is no version to build and compare against, so Kix
/// only moves the Kix library. With `dry_run`, change nothing.
fn pin_only(dir: &Path, version: &Version, dry_run: bool) -> Flow<()> {
    let release = version.release();
    if dry_run {
        println!(
            "This project's flake.lock pins no version of Kix. `kix upgrade --to {release}` would pin the Kix library to {release} in flake.nix and flake.lock (dry run, no files changed)."
        );
        println!("Next: run `kix upgrade --to {release}`.");
        return Ok(());
    }
    let pinned = pin::prepare(dir, None, version).and_then(|plan| pin::pin(None, version, &plan));
    match pinned {
        Ok(files) if files.is_empty() => {
            println!("flake.nix and flake.lock already pin Kix {release}.");
            Ok(())
        }
        Ok(files) => {
            println!(
                "Pinned the Kix library to {release} (updated {}). This project's flake.lock pinned no version of Kix before, so Kix built nothing to compare.",
                out::list(&files)
            );
            let mut commit: Vec<String> = files.iter().map(|f| f.to_string()).collect();
            if modified(dir, kix::project::FILE) {
                commit.push(kix::project::FILE.to_string());
            }
            println!("Commit {}.", out::and_list(&commit));
            Ok(())
        }
        Err(pin::PinError::Edit(edit)) => Err(refused(edit_message(
            &edit,
            "Kix did not change flake.nix or flake.lock.",
            &format!("kix upgrade --to {release}"),
        ))),
        Err(e) => Err(refused(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_the_project_is_on_comes_from_flake_lock() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(project_version(dir.path()).unwrap(), None);
        std::fs::write(
            dir.path().join("flake.lock"),
            r#"{"root": "root", "version": 7, "nodes": {
                "root": {"inputs": {"kix": "kix"}},
                "kix": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.8.0-rc.1"}}
            }}"#,
        )
        .unwrap();
        let v = project_version(dir.path()).unwrap().unwrap();
        assert_eq!(v.release(), "0.8.0-rc.1");
        assert!(v < "0.8.0".parse().unwrap());
    }

    fn v(text: &str) -> Version {
        text.parse().unwrap()
    }

    #[test]
    fn an_older_target_without_to_is_nothing_to_upgrade() {
        let to: Requirement = "0.10".parse().unwrap();
        assert_eq!(
            nothing_to_upgrade(&v("0.10.3"), &v("0.10.3"), Some(&to), None),
            "Already on Kix 0.10.3 (matches target 0.10.3). Nothing to upgrade."
        );
        assert_eq!(
            nothing_to_upgrade(&v("0.10.3"), &v("0.10.3"), None, None),
            "Already on the latest Kix release (0.10.3). Nothing to upgrade."
        );
        assert_eq!(
            nothing_to_upgrade(&v("0.11.0-rc.1"), &v("0.10.3"), None, None),
            "Kix 0.11.0-rc.1 is newer than the latest Kix release (0.10.3). Nothing to upgrade."
        );
        assert_eq!(
            nothing_to_upgrade(&v("0.10.3"), &v("0.10.2"), None, Some(7)),
            "Kix 0.10.3 is newer than Kix 0.10.2, the newest release at least 7 days old (`min-age = \"7d\"` in kix.toml). Nothing to upgrade."
        );
    }

    #[test]
    fn an_older_target_names_the_way_back() {
        assert_eq!(
            older_message(&v("0.10.0-rc.3"), &v("0.10.0-rc.2")),
            "Cannot move this project to Kix 0.10.0-rc.2: it is on Kix 0.10.0-rc.3, and `kix upgrade` only moves a project to a newer version.\nNo project files were modified.\nNext: to go back to Kix 0.10.0-rc.2, restore flake.nix and flake.lock from a commit that pinned it."
        );
    }

    #[test]
    fn no_matching_release_names_the_setting_to_change() {
        let to: Requirement = "0.12".parse().unwrap();
        assert!(
            no_release_message("x86_64-linux", Some(&to), Some(7), Some(1))
                .contains("matches `--to 0.12` and `min-age = \"7d\"` in kix.toml (newest release is 1 day old)")
        );
        assert_eq!(
            no_release_message("x86_64-linux", None, None, None),
            "No Kix release found for x86_64-linux."
        );
    }
}
