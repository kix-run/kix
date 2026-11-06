//! Find the external programs Kix runs.
//!
//! Every program Kix starts, such as `nix`, `kubectl`, and `sops`, comes from
//! [`tool`]. When `KIX_RUNTIME_DIR` names a Kix runtime directory, the program
//! comes from there and nowhere else. Otherwise Kix runs the program of that
//! name on `PATH`.
//!
//! A runtime directory keeps each program in a directory of its own, named
//! after its exact version, such as `helm-4.3.1/bin/helm`, so two versions of
//! one program can ship side by side. When the directory has a
//! `manifest.json`, that file is the index and Kix reads paths only from it:
//!
//! ```json
//! { "programs": [
//!     { "name": "nix", "version": "2.31.3",
//!       "bin": { "nix": "nix-2.31.3/bin/nix", "nix-store": "nix-2.31.3/bin/nix-store" } }
//! ] }
//! ```
//!
//! Without a manifest, Kix finds the programs by their directory names.
//!
//! When `KIX_STORE_ROOT` names a relocated store, [`tool`] also gives the Nix
//! programs an environment that selects that store and ignores the machine's
//! and the user's Nix settings.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

use crate::eval::store::store_root;

/// The environment variable that names a Kix runtime directory.
pub const RUNTIME_DIR_VAR: &str = "KIX_RUNTIME_DIR";

/// The file in a runtime directory that lists its programs.
const MANIFEST: &str = "manifest.json";

/// The experimental Nix features Kix uses.
const NIX_FEATURES: &str = "nix-command flakes pipe-operators";

/// A program Kix runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    Nix,
    /// `nix-store`, which ships as part of the `nix` program.
    NixStore,
    Helm,
    Kubectl,
    Sops,
}

impl Tool {
    /// Return the name the runtime lists this program under.
    pub fn program(self) -> &'static str {
        match self {
            Tool::Nix | Tool::NixStore => "nix",
            Tool::Helm => "helm",
            Tool::Kubectl => "kubectl",
            Tool::Sops => "sops",
        }
    }

    /// Return the file name of the executable.
    pub fn binary(self) -> &'static str {
        match self {
            Tool::NixStore => "nix-store",
            other => other.program(),
        }
    }
}

/// The version of a program a caller needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Want<'a> {
    /// The one version the runtime ships. Fails when it ships several, so
    /// shipping a second version makes every caller state which it needs.
    Shipped,
    /// Exactly this version, for output that depends on the version, such as
    /// a Helm render. A runtime without it is an error, never a substitute.
    Exact(&'a str),
}

/// Why Kix could not find or prepare a program.
#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    #[error("the Kix runtime in {} has no {program}", dir.display())]
    Missing { program: String, dir: PathBuf },

    #[error(
        "Kix needs {program} {version}, but the Kix runtime in {} ships {}",
        dir.display(),
        versions(shipped)
    )]
    NoSuchVersion {
        program: String,
        version: String,
        shipped: Vec<String>,
        dir: PathBuf,
    },

    #[error(
        "the Kix runtime in {} ships {program} in more than one version ({}), and Kix does not know which to run",
        dir.display(),
        versions(shipped)
    )]
    Ambiguous {
        program: String,
        shipped: Vec<String>,
        dir: PathBuf,
    },

    #[error(
        "Kix needs {program} {version} exactly, and only a Kix runtime can provide an exact version. Set {RUNTIME_DIR_VAR} to a runtime that ships it"
    )]
    NoRuntime { program: String, version: String },

    #[error("could not read the Kix runtime manifest {}: {message}", path.display())]
    Manifest { path: PathBuf, message: String },

    #[error("could not read the Kix runtime directory {}: {source}", dir.display())]
    Unreadable {
        dir: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("could not prepare the Nix store at {}: {message}", root.display())]
    Store { root: PathBuf, message: String },
}

fn versions(shipped: &[String]) -> String {
    if shipped.is_empty() {
        "no version of it".to_string()
    } else {
        shipped.join(", ")
    }
}

/// Return a [`Command`] that runs `tool` in the version `want` asks for.
///
/// For the Nix programs, the command also selects the store named by
/// `KIX_STORE_ROOT` when it is set.
pub fn tool(tool: Tool, want: Want) -> Result<Command, RuntimeError> {
    let mut cmd = Command::new(program_path(tool, want)?);
    if tool.program() == "nix"
        && let Some(root) = store_root()
    {
        use_store(&mut cmd, &root)?;
    }
    Ok(cmd)
}

/// Return the path of `tool`'s executable, or its bare name when Kix looks
/// it up on `PATH`.
pub fn program_path(tool: Tool, want: Want) -> Result<PathBuf, RuntimeError> {
    locate(runtime_dir().as_deref(), tool, want)
}

/// Return the runtime directory named by `KIX_RUNTIME_DIR`, or `None` when
/// Kix uses the programs on `PATH`.
pub fn runtime_dir() -> Option<PathBuf> {
    std::env::var_os(RUNTIME_DIR_VAR)
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
}

fn locate(dir: Option<&Path>, tool: Tool, want: Want) -> Result<PathBuf, RuntimeError> {
    let Some(dir) = dir else {
        return match want {
            Want::Shipped => Ok(PathBuf::from(tool.binary())),
            Want::Exact(version) => Err(RuntimeError::NoRuntime {
                program: tool.program().to_string(),
                version: version.to_string(),
            }),
        };
    };
    let shipped = if dir.join(MANIFEST).exists() {
        from_manifest(dir, tool)?
    } else {
        from_layout(dir, tool)?
    };
    select(dir, tool, want, shipped)
}

/// One version of a program in a runtime directory.
#[derive(Debug)]
struct Shipped {
    version: String,
    path: PathBuf,
}

fn select(
    dir: &Path,
    tool: Tool,
    want: Want,
    mut shipped: Vec<Shipped>,
) -> Result<PathBuf, RuntimeError> {
    let program = tool.program().to_string();
    let listed = |shipped: &[Shipped]| shipped.iter().map(|s| s.version.clone()).collect();
    match want {
        Want::Exact(version) => match shipped.iter().position(|s| s.version == version) {
            Some(i) => Ok(shipped.swap_remove(i).path),
            None => Err(RuntimeError::NoSuchVersion {
                program,
                version: version.to_string(),
                shipped: listed(&shipped),
                dir: dir.to_path_buf(),
            }),
        },
        Want::Shipped => match shipped.len() {
            0 => Err(RuntimeError::Missing {
                program,
                dir: dir.to_path_buf(),
            }),
            1 => Ok(shipped.remove(0).path),
            _ => Err(RuntimeError::Ambiguous {
                program,
                shipped: listed(&shipped),
                dir: dir.to_path_buf(),
            }),
        },
    }
}

#[derive(Deserialize)]
struct Manifest {
    programs: Vec<ManifestProgram>,
}

#[derive(Deserialize)]
struct ManifestProgram {
    name: String,
    version: String,
    /// Each executable's file name, mapped to its path in the runtime
    /// directory.
    bin: BTreeMap<String, PathBuf>,
}

fn from_manifest(dir: &Path, tool: Tool) -> Result<Vec<Shipped>, RuntimeError> {
    let path = dir.join(MANIFEST);
    let invalid = |message: String| RuntimeError::Manifest {
        path: path.clone(),
        message,
    };
    let bytes = std::fs::read(&path).map_err(|e| invalid(e.to_string()))?;
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|e| invalid(e.to_string()))?;
    let mut shipped = Vec::new();
    for program in manifest.programs {
        if program.name != tool.program() {
            continue;
        }
        let Some(relative) = program.bin.get(tool.binary()) else {
            continue;
        };
        // A path that leaves the runtime directory would run a program the
        // runtime does not ship.
        if !relative
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
        {
            return Err(invalid(format!(
                "{} {} lists {}, which is not a path inside the runtime directory",
                program.name,
                program.version,
                relative.display()
            )));
        }
        shipped.push(Shipped {
            version: program.version,
            path: dir.join(relative),
        });
    }
    Ok(shipped)
}

/// List the versions of `tool` in directories named `<program>-<version>`,
/// each holding `bin/<binary>`.
fn from_layout(dir: &Path, tool: Tool) -> Result<Vec<Shipped>, RuntimeError> {
    let entries = std::fs::read_dir(dir).map_err(|source| RuntimeError::Unreadable {
        dir: dir.to_path_buf(),
        source,
    })?;
    let prefix = format!("{}-", tool.program());
    let mut shipped: Vec<Shipped> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let version = name
                .strip_prefix(&prefix)
                .filter(|v| v.starts_with(|c: char| c.is_ascii_digit()))?;
            let path = entry.path().join("bin").join(tool.binary());
            path.is_file().then(|| Shipped {
                version: version.to_string(),
                path,
            })
        })
        .collect();
    shipped.sort_by(|a, b| a.version.cmp(&b.version));
    Ok(shipped)
}

/// Point `cmd`, a Nix program, at the relocated store under `root`, with
/// settings Kix writes, so the machine's and the user's Nix settings do not
/// change what it does.
fn use_store(cmd: &mut Command, root: &Path) -> Result<(), RuntimeError> {
    let fail = |message: String| RuntimeError::Store {
        root: root.to_path_buf(),
        message,
    };
    // nix.conf has no quoting, so the root must be one plain word.
    let root_str = root
        .to_str()
        .filter(|r| !r.chars().any(char::is_whitespace))
        .ok_or_else(|| fail("the path must be UTF-8 with no spaces".to_string()))?;
    let conf_dir = root.join("etc/nix");
    let conf = format!(
        "# Kix writes this file each time it runs Nix with this store.\n\
         store = {root_str}\n\
         experimental-features = {NIX_FEATURES}\n"
    );
    write_if_changed(&conf_dir.join("nix.conf"), &conf).map_err(|e| fail(e.to_string()))?;

    cmd.env("NIX_CONF_DIR", &conf_dir)
        .env("NIX_USER_CONF_FILES", "")
        .env("NIX_STATE_DIR", root.join("nix/var/nix"));
    if std::env::var_os("NIX_SSL_CERT_FILE").is_none()
        && std::env::var_os("SSL_CERT_FILE").is_none()
        && let Some(bundle) = ca_bundle()
    {
        cmd.env("NIX_SSL_CERT_FILE", bundle);
    }
    Ok(())
}

/// Write `contents` to `path` through a temporary file, unless the file
/// already holds them, so parallel Kix processes never read a partial file.
fn write_if_changed(path: &Path, contents: &str) -> std::io::Result<()> {
    if std::fs::read_to_string(path).is_ok_and(|old| old == contents) {
        return Ok(());
    }
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".nix.conf.{}", std::process::id()));
    std::fs::write(&tmp, contents)?;
    std::fs::rename(&tmp, path)
}

/// Return the system's CA certificate bundle, which Nix needs to download
/// from a binary cache when it does not read the machine's Nix settings.
fn ca_bundle() -> Option<&'static Path> {
    const CANDIDATES: &[&str] = if cfg!(target_os = "macos") {
        &["/etc/ssl/cert.pem"]
    } else {
        &[
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/pki/tls/cacert.pem",
            "/etc/ssl/cert.pem",
        ]
    };
    CANDIDATES.iter().map(Path::new).find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime(programs: &[(&str, &[&str])]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (versioned, binaries) in programs {
            let bin = dir.path().join(versioned).join("bin");
            std::fs::create_dir_all(&bin).unwrap();
            for b in *binaries {
                std::fs::write(bin.join(b), "").unwrap();
            }
        }
        dir
    }

    #[test]
    fn without_a_runtime_programs_come_from_path() {
        for (tool, name) in [
            (Tool::Nix, "nix"),
            (Tool::NixStore, "nix-store"),
            (Tool::Kubectl, "kubectl"),
            (Tool::Sops, "sops"),
            (Tool::Helm, "helm"),
        ] {
            assert_eq!(
                locate(None, tool, Want::Shipped).unwrap(),
                PathBuf::from(name)
            );
        }
    }

    /// `PATH` cannot promise a version, so an exact version needs a runtime.
    #[test]
    fn an_exact_version_needs_a_runtime() {
        let err = locate(None, Tool::Helm, Want::Exact("4.3.1")).unwrap_err();
        assert!(matches!(err, RuntimeError::NoRuntime { .. }), "{err}");
        assert!(err.to_string().contains("KIX_RUNTIME_DIR"), "{err}");
    }

    #[test]
    fn a_runtime_directory_is_read_by_its_layout() {
        let dir = runtime(&[
            ("nix-2.31.3", &["nix", "nix-store"]),
            ("helm-3.19.1", &["helm"]),
            ("helm-4.3.1", &["helm"]),
            ("sops-3.12.1", &[]),
        ]);
        let d = Some(dir.path());
        assert_eq!(
            locate(d, Tool::Nix, Want::Shipped).unwrap(),
            dir.path().join("nix-2.31.3/bin/nix")
        );
        assert_eq!(
            locate(d, Tool::NixStore, Want::Shipped).unwrap(),
            dir.path().join("nix-2.31.3/bin/nix-store")
        );
        assert_eq!(
            locate(d, Tool::Helm, Want::Exact("4.3.1")).unwrap(),
            dir.path().join("helm-4.3.1/bin/helm")
        );

        let err = locate(d, Tool::Helm, Want::Shipped).unwrap_err();
        assert!(matches!(err, RuntimeError::Ambiguous { .. }), "{err}");
        assert!(err.to_string().contains("3.19.1, 4.3.1"), "{err}");

        let err = locate(d, Tool::Helm, Want::Exact("4.3.2")).unwrap_err();
        assert!(matches!(err, RuntimeError::NoSuchVersion { .. }), "{err}");
        assert!(err.to_string().contains("ships 3.19.1, 4.3.1"), "{err}");

        // A runtime never falls back to `PATH`, even for a program it lacks.
        for tool in [Tool::Kubectl, Tool::Sops] {
            let err = locate(d, tool, Want::Shipped).unwrap_err();
            assert!(matches!(err, RuntimeError::Missing { .. }), "{err}");
        }
    }

    /// With a manifest, the paths it lists win over the directory names.
    #[test]
    fn a_manifest_is_the_index() {
        let dir = runtime(&[("nix-2.31.3", &["nix"]), ("elsewhere", &["nix"])]);
        std::fs::write(
            dir.path().join(MANIFEST),
            r#"{"programs": [
                {"name": "nix", "version": "2.31.3", "bin": {"nix": "elsewhere/bin/nix"}, "files": {}},
                {"name": "kubectl", "version": "1.35.0", "bin": {"kubectl": "k/bin/kubectl"}}
            ]}"#,
        )
        .unwrap();
        let d = Some(dir.path());
        assert_eq!(
            locate(d, Tool::Nix, Want::Shipped).unwrap(),
            dir.path().join("elsewhere/bin/nix")
        );
        assert_eq!(
            locate(d, Tool::Kubectl, Want::Exact("1.35.0")).unwrap(),
            dir.path().join("k/bin/kubectl")
        );
        assert!(matches!(
            locate(d, Tool::NixStore, Want::Shipped).unwrap_err(),
            RuntimeError::Missing { .. }
        ));
    }

    #[test]
    fn a_manifest_path_must_stay_inside_the_runtime() {
        let dir = tempfile::tempdir().unwrap();
        for bad in ["/usr/bin/nix", "../nix", "a/../../nix"] {
            std::fs::write(
                dir.path().join(MANIFEST),
                format!(r#"{{"programs": [{{"name": "nix", "version": "1", "bin": {{"nix": "{bad}"}}}}]}}"#),
            )
            .unwrap();
            let err = locate(Some(dir.path()), Tool::Nix, Want::Shipped).unwrap_err();
            assert!(matches!(err, RuntimeError::Manifest { .. }), "{bad}: {err}");
        }
        std::fs::write(dir.path().join(MANIFEST), "not json").unwrap();
        assert!(matches!(
            locate(Some(dir.path()), Tool::Nix, Want::Shipped).unwrap_err(),
            RuntimeError::Manifest { .. }
        ));
    }

    #[test]
    fn a_missing_runtime_directory_is_named() {
        let err = locate(
            Some(Path::new("/nonexistent/kix")),
            Tool::Nix,
            Want::Shipped,
        )
        .unwrap_err();
        assert!(err.to_string().contains("/nonexistent/kix"), "{err}");
    }

    #[test]
    fn a_relocated_store_gets_its_own_settings() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("store");
        let mut cmd = Command::new("nix");
        use_store(&mut cmd, &root).unwrap();
        let env: BTreeMap<_, _> = cmd
            .get_envs()
            .map(|(k, v)| (k.to_string_lossy().into_owned(), v.map(PathBuf::from)))
            .collect();
        assert_eq!(env["NIX_CONF_DIR"], Some(root.join("etc/nix")));
        assert_eq!(env["NIX_USER_CONF_FILES"], Some(PathBuf::new()));
        assert_eq!(env["NIX_STATE_DIR"], Some(root.join("nix/var/nix")));
        let conf = std::fs::read_to_string(root.join("etc/nix/nix.conf")).unwrap();
        assert!(
            conf.contains(&format!("\nstore = {}\n", root.display())),
            "{conf}"
        );
        assert!(conf.contains("experimental-features = nix-command flakes pipe-operators"));

        assert!(use_store(&mut Command::new("nix"), Path::new("/a b")).is_err());
    }
}
