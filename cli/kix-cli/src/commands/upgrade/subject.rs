//! What one run of `kix upgrade` moves.
//!
//! A project with a `[versions]` table in `kix.toml` holds several versions
//! of Kix, each an input of `flake.nix` (`kix::versions`). `kix upgrade`
//! takes a name: an input moves to a newer release, and a cluster moves to
//! another input. With no name, the input `kix` moves.

use std::path::Path;

use kix::flake_lock::{self, INPUT, ProjectKix};
use kix::version::Version;
use kix::versions::Versions;
use miette::miette;

use super::halt::{Flow, refused};
use super::out;
use super::state::UpgradeState;
use crate::cli::UpgradeArgs;

/// What a run moves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Subject {
    /// Move the input `name` to a newer release. `clusters` are the ones
    /// `[versions]` lists under it, or `None` in a project with no table,
    /// where every cluster uses the input `kix`.
    Input {
        name: String,
        clusters: Option<Vec<String>>,
    },
    /// Move `cluster` from the input `from` to the input `to`. The two are
    /// the same when a stopped run already changed `[versions]`.
    Cluster {
        cluster: String,
        from: String,
        to: String,
    },
}

impl Subject {
    /// Work out what `args` name in the project in `dir`.
    pub(super) fn resolve(dir: &Path, args: &UpgradeArgs) -> Flow<Self> {
        let versions = Versions::read(dir).map_err(|e| refused(e.to_string()))?;
        let Some(name) = args.name.as_deref() else {
            return Ok(Subject::Input {
                name: INPUT.to_string(),
                clusters: versions.map(|v| v.clusters_of(INPUT).to_vec()),
            });
        };
        let Some(versions) = versions else {
            if name == INPUT {
                return Ok(Subject::Input {
                    name: INPUT.to_string(),
                    clusters: None,
                });
            }
            return Err(refused(format!(
                "Cannot upgrade `{name}` on its own: kix.toml has no [versions] table, so every cluster in this project uses the same version of Kix.\nNo project files were modified.\nNext: run `kix upgrade` to upgrade the whole project, or add a [versions] table to kix.toml to keep clusters on different versions."
            )));
        };
        if versions.has_input(name) {
            return Ok(Subject::Input {
                name: name.to_string(),
                clusters: Some(versions.clusters_of(name).to_vec()),
            });
        }
        let Some(from) = versions.input_of(name) else {
            let inputs: Vec<String> = versions.inputs().map(|i| format!("`{i}`")).collect();
            return Err(refused(format!(
                "Cannot upgrade `{name}`: `{name}` is neither an input nor a cluster in kix.toml [versions] (inputs: {}).\nNo project files were modified.\nNext: pass an input or cluster listed in kix.toml [versions], or run `kix list clusters` to see the project's clusters.",
                out::list(&inputs)
            )));
        };
        let to = args.to.as_deref().unwrap_or(INPUT);
        // The table says which inputs are versions of Kix, so a cluster
        // moves only to an input it names.
        let known = versions.has_input(to);
        if !known {
            if to.parse::<kix::version::policy::Requirement>().is_ok() {
                return Err(refused(format!(
                    "Cannot upgrade cluster `{name}` with `--to {to}`: when upgrading a cluster, `--to` takes an input name (such as `kix`), whereas `{to}` looks like a Kix version.\nNo project files were modified.\nNext: run `kix upgrade {name}` to move `{name}` to input `kix`, or run `kix upgrade {from} --to {to}` to upgrade input `{from}` (and every cluster on it) to {to}."
                )));
            }
            let inputs: Vec<String> = versions.inputs().map(|i| format!("`{i}`")).collect();
            return Err(refused(format!(
                "Cannot move cluster `{name}` to `{to}`: `{to}` is not listed in kix.toml [versions] (inputs: {}).\nNo project files were modified.\nNext: pass an existing input with `--to`, or add `inputs.{to}.url` to flake.nix and `{to} = []` to kix.toml [versions], run `kix upgrade {to}` to lock it, and run `kix upgrade {name} --to {to}` again.",
                out::list(&inputs)
            )));
        }
        Ok(Subject::Cluster {
            cluster: name.to_string(),
            from: from.to_string(),
            to: to.to_string(),
        })
    }

    /// Return the input whose release tag in `flake.lock` this run changes,
    /// or `None` for a cluster, which changes only `kix.toml`.
    pub(super) fn input(&self) -> Option<&str> {
        match self {
            Subject::Input { name, .. } => Some(name),
            Subject::Cluster { .. } => None,
        }
    }

    /// Return the clusters this run builds, or `None` for every cluster of
    /// the project.
    pub(super) fn clusters(&self) -> Option<Vec<String>> {
        match self {
            Subject::Input { clusters, .. } => clusters.clone(),
            Subject::Cluster { cluster, .. } => Some(vec![cluster.clone()]),
        }
    }

    /// Return the command that runs this upgrade again.
    pub(super) fn command(&self) -> String {
        match self {
            Subject::Input { name, .. } if name == INPUT => "kix upgrade".to_string(),
            Subject::Input { name, .. } => format!("kix upgrade {name}"),
            Subject::Cluster { cluster, to, .. } => format!("kix upgrade {cluster} --to {to}"),
        }
    }

    /// Return the folder name that keeps this run's builds apart from those
    /// of another input or cluster, or `None` for the input `kix`.
    pub(super) fn work_name(&self) -> Option<String> {
        match self {
            Subject::Input { name, .. } if name == INPUT => None,
            Subject::Input { name, .. } => Some(format!("input-{name}")),
            Subject::Cluster { cluster, .. } => Some(format!("cluster-{cluster}")),
        }
    }

    /// Return whether `state` is a run of this same upgrade.
    pub(super) fn wrote(&self, state: &UpgradeState) -> bool {
        match self {
            Subject::Input { name, .. } => {
                state.cluster.is_none() && state.input.as_deref().unwrap_or(INPUT) == name
            }
            Subject::Cluster { cluster, to, .. } => {
                state.cluster.as_deref() == Some(cluster) && state.input.as_deref() == Some(to)
            }
        }
    }

    /// Return what a failed step leaves the project on, for the lines that
    /// say where an upgrade stopped.
    pub(super) fn left_on(&self, version: &Version) -> String {
        match self {
            Subject::Input { name, .. } if name == INPUT => format!(
                "flake.nix and flake.lock are pinned to {}",
                version.release()
            ),
            Subject::Input { name, .. } => format!(
                "Input `{name}` is pinned to {} in flake.nix and flake.lock",
                version.release()
            ),
            Subject::Cluster { cluster, to, .. } => format!(
                "kix.toml now lists cluster `{cluster}` under `{to}` (Kix {})",
                version.release()
            ),
        }
    }
}

/// Return the command that upgrades the input `input`.
pub(super) fn input_command(input: &str) -> String {
    if input == INPUT {
        "kix upgrade".to_string()
    } else {
        format!("kix upgrade {input}")
    }
}

/// Return the command that goes on with the upgrade `state` records.
pub(super) fn command_of(state: &UpgradeState) -> String {
    match (&state.cluster, state.input.as_deref()) {
        (Some(cluster), Some(to)) => format!("kix upgrade {cluster} --to {to}"),
        (_, Some(input)) if input != INPUT => format!("kix upgrade {input}"),
        _ => "kix upgrade".to_string(),
    }
}

/// Return the release the input `input` of the project in `dir` pins, or
/// `None` when it is a folder or a branch.
pub(super) fn release_of(dir: &Path, input: &str) -> Flow<Option<Version>> {
    let lock = flake_lock::read(dir).map_err(|e| refused(e.to_string()))?;
    let original = flake_lock::input(&lock, input)
        .map_err(|e| refused(format!("{}.", e.change_of(input, "<version>"))))?;
    match flake_lock::from_original(original) {
        Ok(ProjectKix::Release(v)) => Ok(Some(v)),
        Ok(ProjectKix::Development(_)) => Ok(None),
        Err(e) => Err(miette!("{e}").into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(toml: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("kix.toml"), toml).unwrap();
        std::fs::write(
            dir.path().join("flake.lock"),
            r#"{"root": "root", "version": 7, "nodes": {
                "root": {"inputs": {"kix": "kix", "kix-stable": "kix-stable", "kix-next": "kix-next"}},
                "kix": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.12.0"}},
                "kix-stable": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.11.3"}},
                "kix-next": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "main"}}
            }}"#,
        )
        .unwrap();
        dir
    }

    fn args(name: Option<&str>, to: Option<&str>) -> UpgradeArgs {
        UpgradeArgs {
            name: name.map(str::to_owned),
            to: to.map(str::to_owned),
            dry_run: false,
            acknowledge: Vec::new(),
        }
    }

    const TABLE: &str = "[versions]\nkix = [\"staging\"]\nkix-stable = [\"prod\", \"eu\"]\n";

    #[test]
    fn a_name_is_an_input_or_a_cluster() {
        let dir = project(TABLE);
        let resolve = |name, to| Subject::resolve(dir.path(), &args(name, to));
        assert_eq!(
            resolve(None, None).unwrap(),
            Subject::Input {
                name: "kix".into(),
                clusters: Some(vec!["staging".into()])
            }
        );
        let stable = resolve(Some("kix-stable"), Some("0.11.4")).unwrap();
        assert_eq!(stable.clusters().unwrap(), ["prod", "eu"]);
        assert_eq!(stable.command(), "kix upgrade kix-stable");
        let prod = resolve(Some("prod"), None).unwrap();
        assert_eq!(
            prod,
            Subject::Cluster {
                cluster: "prod".into(),
                from: "kix-stable".into(),
                to: "kix".into()
            }
        );
        assert_eq!(prod.command(), "kix upgrade prod --to kix");
        // An input the table does not name is no place to move to, even
        // when flake.lock has it.
        assert!(resolve(Some("prod"), Some("kix-next")).is_err());
        assert!(resolve(Some("prod"), Some("0.12.0")).is_err());
        assert!(resolve(Some("dev"), None).is_err());
    }

    #[test]
    fn a_project_with_one_version_takes_no_name() {
        let dir = project("builder = \"kix\"\n");
        let resolve = |name| Subject::resolve(dir.path(), &args(name, None));
        assert_eq!(
            resolve(None).unwrap(),
            Subject::Input {
                name: "kix".into(),
                clusters: None
            }
        );
        assert!(resolve(Some("kix")).is_ok());
        assert!(resolve(Some("prod")).is_err());
    }

    #[test]
    fn the_release_of_an_input_comes_from_the_lock() {
        let dir = project(TABLE);
        let release = |input| release_of(dir.path(), input).unwrap();
        assert_eq!(release("kix-stable").unwrap().release(), "0.11.3");
        assert_eq!(release("kix-next"), None);
        assert!(release_of(dir.path(), "kix-old").is_err());
    }
}
