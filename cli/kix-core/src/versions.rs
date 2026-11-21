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
        "Invalid `{0}` in kix.toml [versions]: map each input name to a list of cluster names, such as `kix = [\"staging\"]` and `kix-stable = [\"prod\"]`."
    )]
    Shape(String),
    #[error(
        "kix.toml [versions] lists cluster `{cluster}` under both `{first}` and `{second}`. Remove `{cluster}` from one of those lists so each cluster uses a single input."
    )]
    Twice {
        cluster: String,
        first: String,
        second: String,
    },
    #[error(
        "Cluster `{cluster}` is not listed in kix.toml [versions]. Check the spelling (run `kix list clusters` to see defined clusters), or add `\"{cluster}\"` to one of the lists in kix.toml [versions] ({inputs})."
    )]
    Unlisted { cluster: String, inputs: String },
    #[error(
        "kix.toml [versions] names input `{input}`, which is missing from flake.nix. Add `inputs.{input}.url = \"github:kix-run/kix/v<version>\";` to flake.nix, then run `kix upgrade {input}` to lock it."
    )]
    NoInput { input: String },
    #[error(
        "Input `{input}` is defined in flake.nix and kix.toml [versions], but is not locked in flake.lock yet. Run `kix upgrade {input}` to lock it."
    )]
    NotLocked { input: String },
    #[error(
        "kix.toml [versions] lists a cluster named `{name}`, which collides with the input `{name}` (`kix upgrade {name}` would be ambiguous). {}",
        if name.as_str() == INPUT {
            "Rename the cluster `kix` in flake.nix and kix.toml [versions] (the main Kix input must stay named `kix`).".to_string()
        } else {
            format!("Rename input `{name}` in flake.nix and kix.toml [versions], then run `kix upgrade <new-input>` to lock it.")
        }
    )]
    NameClash { name: String },
    #[error(
        "Cannot evaluate clusters on input `{input}`: flake.lock locks `{input}` with an input type Kix cannot pass as a flake reference. Kix supports `github:`, `gitlab:`, `sourcehut:`, `git+`, and `path:` inputs in kix.toml [versions]. Change `inputs.{input}.url` in flake.nix to one of those forms (for a release tag, run `kix upgrade {input}` to lock it)."
    )]
    LockedKind { input: String },
    #[error(
        "kix.toml cannot set `library = \"self\"` together with a `[versions]` table: a project whose own flake provides the Kix library has only one version of Kix. Remove `[versions]` (or remove `library = \"self\"`) from kix.toml."
    )]
    OwnLibrary,
    #[error(
        "Kix could not update [versions] in kix.toml: {0}. Move `\"{1}\"` under `{2}` in kix.toml [versions] yourself."
    )]
    Edit(String, String, String),
    #[error(
        "Input `{input}` pins Kix {newer}, which is newer than Kix {kix} on input `kix`. Input `kix` must pin the newest version in the project, and every command that builds or deploys a cluster (along with `kix upgrade`) stops until it does. Restore flake.nix and flake.lock from a commit where `{input}` pinned Kix {kix} or older."
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
        if let Some(name) = owner
            .keys()
            .find(|cluster| *cluster == INPUT || inputs.contains_key(*cluster))
        {
            return Err(VersionsError::NameClash { name: name.clone() });
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

    /// Return the clusters the table lists under `input`.
    pub fn clusters_of(&self, input: &str) -> &[String] {
        self.inputs.get(input).map_or(&[], Vec::as_slice)
    }

    /// Return whether `name` is an input the table can list clusters under:
    /// one of its keys, or `kix`.
    pub fn has_input(&self, name: &str) -> bool {
        name == INPUT || self.inputs.contains_key(name)
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
    ///
    /// `flake` is the text of `flake.nix`, which tells an input that is
    /// not locked yet from one that does not exist.
    pub fn check(&self, lock: &Value, flake: &str) -> Result<(), VersionsError> {
        let release = |input: &str| match flake_lock::input(lock, input) {
            Err(_) if input != INPUT && crate::pin_library::names_input(flake, input) => {
                Err(VersionsError::NotLocked {
                    input: input.to_string(),
                })
            }
            Err(_) if input != INPUT => Err(VersionsError::NoInput {
                input: input.to_string(),
            }),
            // The reading of the input `kix` reports its own absence.
            Err(_) => Ok(None),
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
    versions.check(&lock, &flake_text(dir))?;
    let Some(cluster) = cluster else {
        return Ok(());
    };
    let input = versions
        .input_of(cluster)
        .ok_or_else(|| versions.unlisted(cluster))?;
    let swap = match input {
        INPUT => None,
        other => Some(
            locked_ref(&lock, other).ok_or_else(|| VersionsError::LockedKind {
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

/// Return the text of the `flake.nix` in `dir`, or nothing when Kix cannot
/// read it.
pub fn flake_text(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("flake.nix")).unwrap_or_default()
}

/// Return whether the Kix that runs is older than the one the input `kix`
/// of the project in `dir` pins, in a project with a `[versions]` table.
///
/// Every version of Kix in a project reads the same `kix.toml`. The Kix of
/// the input `kix` is the newest, knows every setting, and checks them all.
/// An older Kix skips the settings it does not know.
pub fn held_back(dir: &Path) -> bool {
    if !matches!(Versions::read(dir), Ok(Some(_))) {
        return false;
    }
    let Ok(lock) = flake_lock::read(dir) else {
        return false;
    };
    matches!(
        flake_lock::input(&lock, INPUT).map(flake_lock::from_original),
        Ok(Ok(ProjectKix::Release(newest))) if crate::version::running() < &newest
    )
}

/// Move `cluster` to the list of `to` in the `[versions]` table of the
/// `kix.toml` in `dir`, keeping the rest of the file as it is.
pub fn move_cluster(dir: &Path, cluster: &str, to: &str) -> Result<(), VersionsError> {
    let path = dir.join(crate::project::FILE);
    let edit = |why: &str| VersionsError::Edit(why.to_string(), cluster.into(), to.into());
    let text = std::fs::read_to_string(&path).map_err(|e| edit(&e.to_string()))?;
    // Read the new text back, so a wrong edit never reaches the file. It
    // must hold the settings of the old text, with only this cluster moved.
    let moved = moved_text(&text, cluster, to)
        .filter(|moved| {
            let read = |text: &str| toml::from_str::<toml::Table>(text).ok();
            let expected = read(&text).and_then(|table| moved_table(table, cluster, to));
            expected.is_some() && expected == read(moved)
        })
        .ok_or_else(|| {
            edit("Kix could not confirm its edit of the [versions] table (kix.toml was not modified)")
        })?;
    std::fs::write(&path, moved).map_err(|e| edit(&e.to_string()))
}

/// Return the settings of a `kix.toml` with `cluster` moved to the list of
/// `to` in `[versions]`, or `None` when the table is not lists of names.
fn moved_table(mut table: toml::Table, cluster: &str, to: &str) -> Option<toml::Table> {
    let versions = table.get_mut(TABLE)?.as_table_mut()?;
    for (_, list) in versions.iter_mut() {
        list.as_array_mut()?
            .retain(|name| name.as_str() != Some(cluster));
    }
    versions
        .entry(to)
        .or_insert_with(|| toml::Value::Array(Vec::new()))
        .as_array_mut()?
        .push(cluster.into());
    Some(table)
}

/// Return `text`, a `kix.toml`, with `cluster` moved to the list of `to` in
/// `[versions]`, or `None` when Kix cannot find the lists. Comments and
/// layout outside the lists that change stay as they are.
fn moved_text(text: &str, cluster: &str, to: &str) -> Option<String> {
    let mut document: toml_edit::DocumentMut = text.parse().ok()?;
    let versions = document.get_mut(TABLE)?.as_table_like_mut()?;
    for (_, list) in versions.iter_mut() {
        let list = list.as_array_mut()?;
        list.retain(|name| name.as_str() != Some(cluster));
        // The name that is now first keeps the space that followed the
        // comma before it.
        if let Some(first) = list.iter_mut().next()
            && first.decor().prefix().and_then(|p| p.as_str()) == Some(" ")
        {
            first.decor_mut().set_prefix("");
        }
    }
    match versions.get_mut(to) {
        Some(list) => list.as_array_mut()?.push(cluster),
        None => {
            let mut list = toml_edit::Array::new();
            list.push(cluster);
            versions.insert(to, toml_edit::value(list));
        }
    }
    Some(document.to_string())
}

/// Return a flake reference for exactly what `lock` pins for the project's
/// input `name`, or `None` when the lock has no such input or Kix cannot
/// write its kind as a reference.
pub fn locked_ref(lock: &Value, name: &str) -> Option<String> {
    let root = lock["root"].as_str().unwrap_or("root");
    let key = lock["nodes"][root]["inputs"][name].as_str()?;
    let locked = &lock["nodes"][key]["locked"];
    let s = |k: &str| locked[k].as_str();
    // The settings that follow `?` in a reference.
    let mut query = Vec::new();
    let mut base = match s("type")? {
        kind @ ("github" | "gitlab" | "sourcehut") => {
            if let Some(host) = s("host") {
                query.push(format!("host={host}"));
            }
            format!("{kind}:{}/{}/{}", s("owner")?, s("repo")?, s("rev")?)
        }
        "git" => {
            query.push(format!("rev={}", s("rev")?));
            if let Some(r) = s("ref") {
                query.push(format!("ref={r}"));
            }
            if locked["submodules"].as_bool() == Some(true) {
                query.push("submodules=1".to_string());
            }
            format!("git+{}", s("url")?)
        }
        "path" => format!("path:{}", s("path")?),
        _ => return None,
    };
    if let Some(dir) = s("dir") {
        query.push(format!("dir={dir}"));
    }
    if !query.is_empty() {
        base.push('?');
        base.push_str(&query.join("&"));
    }
    Some(base)
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
        assert_eq!(v.check(&lock("v0.12.0", "v0.11.3"), ""), Ok(()));
        assert_eq!(v.check(&lock("v0.12.0", "v0.12.0"), ""), Ok(()));
        let e = v.check(&lock("v0.11.3", "v0.12.0"), "").unwrap_err();
        assert!(matches!(e, VersionsError::NewerThanKix { .. }), "{e}");
    }

    #[test]
    fn an_input_the_lock_does_not_hold_says_whether_flake_nix_names_it() {
        let v = versions("[versions]\nkix = [\"staging\"]\nkix-old = [\"prod\"]").unwrap();
        let lock = lock("v0.12.0", "v0.11.3");
        let e = v.check(&lock, "").unwrap_err();
        assert!(matches!(e, VersionsError::NoInput { .. }), "{e}");
        let flake = "inputs.kix-old.url = \"github:kix-run/kix/v0.11.0\";";
        let e = v.check(&lock, flake).unwrap_err();
        assert_eq!(
            e.to_string(),
            "Input `kix-old` is defined in flake.nix and kix.toml [versions], but is not locked in flake.lock yet. Run `kix upgrade kix-old` to lock it."
        );
    }

    #[test]
    fn a_cluster_may_not_have_the_name_of_an_input() {
        for text in [
            "[versions]\nkix = [\"kix-stable\"]\nkix-stable = [\"prod\"]",
            "[versions]\nkix-stable = [\"kix\"]",
        ] {
            let e = versions(text).unwrap_err();
            assert!(matches!(e, VersionsError::NameClash { .. }), "{e}");
        }
    }

    #[test]
    fn a_cluster_moves_between_lists_and_the_rest_stays() {
        let text = "# Project settings\nbuilder = \"kix\"\n\n[versions]\n# newest\nkix        = [\"staging\"]\nkix-stable = [\"prod\", \"eu\"]  # held back\n\n[upgrade]\nmin-age = \"7d\"\n";
        assert_eq!(
            moved_text(text, "prod", "kix").unwrap(),
            "# Project settings\nbuilder = \"kix\"\n\n[versions]\n# newest\nkix        = [\"staging\", \"prod\"]\nkix-stable = [\"eu\"]  # held back\n\n[upgrade]\nmin-age = \"7d\"\n"
        );
        // A list over several lines keeps its layout.
        let text = "[versions]\nkix = []\nkix-stable = [\n  \"prod\",\n  \"eu\",\n]\n";
        assert_eq!(
            moved_text(text, "eu", "kix").unwrap(),
            "[versions]\nkix = [\"eu\"]\nkix-stable = [\n  \"prod\",\n]\n"
        );
        // An input the table does not list yet gets a line.
        let text = "[versions]\nkix-stable = [\"prod\"]\n\n[upgrade]\nmin-age = \"7d\"\n";
        assert_eq!(
            moved_text(text, "prod", "kix").unwrap(),
            "[versions]\nkix-stable = []\nkix = [\"prod\"]\n\n[upgrade]\nmin-age = \"7d\"\n"
        );
        assert_eq!(moved_text("builder = \"kix\"\n", "a", "b"), None);
    }

    /// The table a `kix.toml` text holds, as input and its clusters.
    fn table_of(text: &str) -> Vec<(String, Vec<String>)> {
        let v = versions(text).unwrap();
        v.inputs()
            .map(|i| (i.to_string(), v.clusters_of(i).to_vec()))
            .collect()
    }

    #[test]
    fn a_move_keeps_every_other_name_however_the_file_is_written() {
        let moved = |text: &str| {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join(crate::project::FILE);
            std::fs::write(&path, text).unwrap();
            move_cluster(dir.path(), "prod", "kix").unwrap();
            std::fs::read_to_string(path).unwrap()
        };
        let want = vec![
            (
                "kix".to_string(),
                vec!["staging".to_string(), "prod".to_string()],
            ),
            ("kix-stable".to_string(), vec!["eu".to_string()]),
        ];
        for text in [
            // Names in single quotes.
            "[versions]\nkix = ['staging']\nkix-stable = ['prod', 'eu']\n",
            // Windows line endings, and text before the table that is not ASCII.
            "# clústeres\r\nbuilder = \"kix\"\r\n\r\n[versions]\r\nkix = [\"staging\"]\r\nkix-stable = [\"prod\", \"eu\"]\r\n",
            // A comment inside a list, and one after the table's heading.
            "[versions] # who runs what\nkix = [\"staging\"]\nkix-stable = [\n  \"prod\", # moves next\n  \"eu\",\n]\n",
            // The table written with dotted keys.
            "versions.kix = [\"staging\"]\nversions.kix-stable = [\"prod\", \"eu\"]\n",
        ] {
            assert_eq!(table_of(&moved(text)), want, "{text}");
        }
        let kept = moved(
            "[versions] # who runs what\nkix = [\"staging\"]\nkix-stable = [\"prod\"] # held back\n",
        );
        assert!(
            kept.contains("# who runs what") && kept.contains("# held back"),
            "{kept}"
        );
    }

    #[test]
    fn the_swap_names_the_locked_revision() {
        assert_eq!(
            locked_ref(&lock("v0.12.0", "v0.11.3"), "kix-stable").as_deref(),
            Some("github:kix-run/kix/rev-of-v0.11.3")
        );
        assert_eq!(locked_ref(&lock("v0.12.0", "v0.11.3"), "kix-none"), None);
        let with = |locked: Value| {
            let lock = json!({"root": "root", "nodes": {
                "root": {"inputs": {"kix-stable": "s"}}, "s": {"locked": locked}}});
            locked_ref(&lock, "kix-stable")
        };
        assert_eq!(
            with(
                json!({"type": "github", "owner": "o", "repo": "r", "rev": "abc",
                "host": "git.example.com", "dir": "kix"})
            )
            .as_deref(),
            Some("github:o/r/abc?host=git.example.com&dir=kix")
        );
        assert_eq!(
            with(json!({"type": "gitlab", "owner": "o", "repo": "r", "rev": "abc"})).as_deref(),
            Some("gitlab:o/r/abc")
        );
        assert_eq!(
            with(json!({"type": "sourcehut", "owner": "~o", "repo": "r", "rev": "abc"})).as_deref(),
            Some("sourcehut:~o/r/abc")
        );
        assert_eq!(
            with(
                json!({"type": "git", "url": "https://example.com/r", "rev": "abc",
                "ref": "refs/tags/v1", "submodules": true})
            )
            .as_deref(),
            Some("git+https://example.com/r?rev=abc&ref=refs/tags/v1&submodules=1")
        );
        assert_eq!(
            with(json!({"type": "tarball", "url": "https://example.com/r.tgz"})),
            None
        );
    }
}
