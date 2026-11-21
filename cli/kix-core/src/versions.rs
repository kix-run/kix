//! Read which Kix library input each cluster of a project uses.
//!
//! A project may hold several versions of Kix. Each is an input of its
//! `flake.nix`: `kix`, and one more for each version a cluster is held back
//! on, such as `kix-stable`. The `[versions]` table of `kix.toml` lists the
//! clusters that use each input. `flake.lock` still holds every version.
//!
//! The outputs of `flake.nix` read only the input `kix`. For a cluster on
//! another input, Kix evaluates the project with `kix` replaced by that
//! input ([`Chosen::swap`]), so the Kix that runs a cluster always evaluates
//! the whole project with its own library.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use serde_json::Value;

use crate::flake_lock::{self, INPUT, ProjectKix};

/// The name of the table in `kix.toml`.
pub const TABLE: &str = "versions";

/// The `[versions]` table: each input name and the clusters that use it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Versions {
    inputs: BTreeMap<String, Vec<String>>,
}

/// Why Kix cannot use a project's `[versions]` table.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum VersionsError {
    #[error(
        "kix.toml [versions] must map each input name to a list of cluster names, such as `kix-stable = [\"prod\"]`, and `{0}` is not a list of names."
    )]
    Shape(String),
    #[error(
        "kix.toml [versions] lists the cluster `{cluster}` under both `{first}` and `{second}`. List it under one."
    )]
    Twice {
        cluster: String,
        first: String,
        second: String,
    },
    #[error(
        "kix.toml [versions] does not list the cluster `{cluster}`. Add it to one of: {inputs}."
    )]
    Unlisted { cluster: String, inputs: String },
    #[error(
        "kix.toml [versions] names the input `{input}`, and flake.lock has no input of that name. Add `inputs.{input}.url = \"github:kix-run/kix/v<version>\";` to flake.nix."
    )]
    NoInput { input: String },
    #[error(
        "The input `{input}` pins Kix {newer}, which is newer than the Kix {kix} that the input `kix` pins. The input `kix` must pin the newest version in the project. Run `kix upgrade`, or point the clusters under `{input}` at `kix`."
    )]
    NewerThanKix {
        input: String,
        newer: String,
        kix: String,
    },
    #[error("{0}")]
    Lock(String),
}

impl Versions {
    /// Read the `[versions]` table of the `kix.toml` in `dir`. Return `None`
    /// when the file has no such table, which means the project has one
    /// version.
    ///
    /// Kix reads this before it knows which version runs the command, so a
    /// missing or unreadable file and invalid TOML count as no table and are
    /// left to the full reading of `kix.toml`.
    pub fn read(dir: &Path) -> Result<Option<Self>, VersionsError> {
        let Some(text) = std::fs::read_to_string(dir.join(crate::project::FILE)).ok() else {
            return Ok(None);
        };
        let Ok(table) = toml::from_str::<toml::Table>(&text) else {
            return Ok(None);
        };
        match table.get(TABLE) {
            None => Ok(None),
            Some(value) => Self::parse(value).map(Some),
        }
    }

    /// Parse the value of the `versions` key.
    pub fn parse(value: &toml::Value) -> Result<Self, VersionsError> {
        let table = value
            .as_table()
            .ok_or_else(|| VersionsError::Shape(TABLE.to_string()))?;
        let mut inputs = BTreeMap::new();
        let mut owner: BTreeMap<String, String> = BTreeMap::new();
        for (input, clusters) in table {
            let shape = || VersionsError::Shape(input.clone());
            let clusters = clusters
                .as_array()
                .ok_or_else(shape)?
                .iter()
                .map(|c| c.as_str().map(str::to_owned).ok_or_else(shape))
                .collect::<Result<Vec<_>, _>>()?;
            for cluster in &clusters {
                if let Some(first) = owner.insert(cluster.clone(), input.clone()) {
                    return Err(VersionsError::Twice {
                        cluster: cluster.clone(),
                        first,
                        second: input.clone(),
                    });
                }
            }
            inputs.insert(input.clone(), clusters);
        }
        Ok(Self { inputs })
    }

    /// Return the input the cluster `cluster` uses, or `None` when the table
    /// does not list it.
    pub fn input_of(&self, cluster: &str) -> Option<&str> {
        self.inputs
            .iter()
            .find(|(_, clusters)| clusters.iter().any(|c| c == cluster))
            .map(|(input, _)| input.as_str())
    }

    /// Return the input names, in order.
    pub fn inputs(&self) -> impl Iterator<Item = &str> {
        self.inputs.keys().map(String::as_str)
    }

    /// Return the error for a cluster the table does not list.
    pub fn unlisted(&self, cluster: &str) -> VersionsError {
        VersionsError::Unlisted {
            cluster: cluster.to_string(),
            inputs: self
                .inputs()
                .map(|i| format!("`{i}`"))
                .collect::<Vec<_>>()
                .join(", "),
        }
    }

    /// Check the table against `lock`: every input it names is an input of
    /// the project, and none pins a newer release than `kix`.
    pub fn check(&self, lock: &Value) -> Result<(), VersionsError> {
        let release = |input: &str| match flake_lock::input(lock, input) {
            Err(_) => Err(VersionsError::NoInput {
                input: input.to_string(),
            }),
            Ok(original) => Ok(match flake_lock::from_original(original) {
                Ok(ProjectKix::Release(v)) => Some(v),
                // A folder or a branch has no release to compare.
                _ => None,
            }),
        };
        let kix = release(INPUT)?;
        for input in self.inputs().filter(|i| *i != INPUT) {
            if let (Some(kix), Some(other)) = (&kix, release(input)?)
                && &other > kix
            {
                return Err(VersionsError::NewerThanKix {
                    input: input.to_string(),
                    newer: other.release(),
                    kix: kix.release(),
                });
            }
        }
        Ok(())
    }
}

/// The input Kix chose for the cluster a command names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chosen {
    /// The name of the input, such as `kix-stable`.
    pub input: String,
    /// The flake reference that replaces the input `kix` during evaluation,
    /// or `None` when the cluster uses `kix` itself.
    pub swap: Option<String>,
}

static CHOSEN: OnceLock<Chosen> = OnceLock::new();

/// Return the input chosen for this run, or `None` when the project has no
/// `[versions]` table or the command names no cluster.
pub fn chosen() -> Option<&'static Chosen> {
    CHOSEN.get()
}

/// Return the name of the input whose release is this run's version of Kix.
pub fn chosen_input() -> &'static str {
    chosen().map_or(INPUT, |c| c.input.as_str())
}

/// Choose the input for `cluster` in the project in `dir`, once per run.
/// A project with no `[versions]` table, and a command that names no
/// cluster, use the input `kix`.
pub fn choose(dir: &Path, cluster: Option<&str>) -> Result<(), VersionsError> {
    let Some(versions) = Versions::read(dir)? else {
        return Ok(());
    };
    let lock = flake_lock::read(dir).map_err(|e| VersionsError::Lock(e.to_string()))?;
    versions.check(&lock)?;
    let Some(cluster) = cluster else {
        return Ok(());
    };
    let input = versions
        .input_of(cluster)
        .ok_or_else(|| versions.unlisted(cluster))?;
    let swap = match input {
        INPUT => None,
        other => Some(
            locked_ref(&lock, other).ok_or_else(|| VersionsError::NoInput {
                input: other.to_string(),
            })?,
        ),
    };
    let _ = CHOSEN.set(Chosen {
        input: input.to_string(),
        swap,
    });
    Ok(())
}

/// Return a flake reference for exactly what `lock` pins for the project's
/// input `name`, or `None` when the lock has no such input or Kix cannot
/// write its kind as a reference.
pub fn locked_ref(lock: &Value, name: &str) -> Option<String> {
    let root = lock["root"].as_str().unwrap_or("root");
    let key = lock["nodes"][root]["inputs"][name].as_str()?;
    let locked = &lock["nodes"][key]["locked"];
    let s = |k: &str| locked[k].as_str();
    match s("type")? {
        "github" => Some(format!(
            "github:{}/{}/{}",
            s("owner")?,
            s("repo")?,
            s("rev")?
        )),
        "git" => {
            let mut url = format!("git+{}?rev={}", s("url")?, s("rev")?);
            if let Some(r) = s("ref") {
                url.push_str(&format!("&ref={r}"));
            }
            Some(url)
        }
        "path" => Some(format!("path:{}", s("path")?)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn versions(text: &str) -> Result<Versions, VersionsError> {
        let table: toml::Table = toml::from_str(text).unwrap();
        Versions::parse(&table[TABLE])
    }

    fn lock(kix: &str, stable: &str) -> Value {
        let node = |tag: &str| {
            json!({
                "original": { "type": "github", "owner": "kix-run", "repo": "kix", "ref": tag },
                "locked": { "type": "github", "owner": "kix-run", "repo": "kix", "rev": format!("rev-of-{tag}") },
            })
        };
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kix": "kix", "kix-stable": "kix-stable" } },
                "kix": node(kix),
                "kix-stable": node(stable),
            }
        })
    }

    #[test]
    fn a_cluster_uses_the_input_that_lists_it() {
        let v =
            versions("[versions]\nkix = [\"staging\"]\nkix-stable = [\"prod\", \"eu\"]").unwrap();
        assert_eq!(v.input_of("staging"), Some("kix"));
        assert_eq!(v.input_of("eu"), Some("kix-stable"));
        assert_eq!(v.input_of("dev"), None);
        assert!(
            v.unlisted("dev")
                .to_string()
                .contains("`kix`, `kix-stable`")
        );
    }

    #[test]
    fn a_cluster_listed_twice_is_refused() {
        let e = versions("[versions]\nkix = [\"prod\"]\nkix-stable = [\"prod\"]").unwrap_err();
        assert!(matches!(e, VersionsError::Twice { .. }), "{e}");
    }

    #[test]
    fn kix_pins_the_newest_release() {
        let v = versions("[versions]\nkix = [\"staging\"]\nkix-stable = [\"prod\"]").unwrap();
        assert_eq!(v.check(&lock("v0.12.0", "v0.11.3")), Ok(()));
        assert_eq!(v.check(&lock("v0.12.0", "v0.12.0")), Ok(()));
        let e = v.check(&lock("v0.11.3", "v0.12.0")).unwrap_err();
        assert!(matches!(e, VersionsError::NewerThanKix { .. }), "{e}");
        let v = versions("[versions]\nkix = [\"staging\"]\nkix-old = [\"prod\"]").unwrap();
        let e = v.check(&lock("v0.12.0", "v0.11.3")).unwrap_err();
        assert!(matches!(e, VersionsError::NoInput { .. }), "{e}");
    }

    #[test]
    fn the_swap_names_the_locked_revision() {
        assert_eq!(
            locked_ref(&lock("v0.12.0", "v0.11.3"), "kix-stable").as_deref(),
            Some("github:kix-run/kix/rev-of-v0.11.3")
        );
        assert_eq!(locked_ref(&lock("v0.12.0", "v0.11.3"), "kix-none"), None);
    }
}
