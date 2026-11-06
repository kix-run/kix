//! Find the external programs Kix runs.
//!
//! Every program Kix starts, such as `nix`, `kubectl`, and `sops`, comes from
//! [`tool`]. Kix looks for a runtime directory in this order and uses the
//! first it finds:
//!
//! 1. the directory `KIX_RUNTIME_DIR` names,
//! 2. `../libexec/kix/` beside the running `kix` binary, when it holds a
//!    `manifest.json`,
//! 3. the directory compiled in from `KIX_BUILTIN_RUNTIME_DIR` at build time,
//!    for a package of Kix that keeps the runtime elsewhere, when it holds a
//!    `manifest.json`.
//!
//! With a runtime directory, every program comes from there and nowhere else.
//! Without one, Kix runs the program of that name on `PATH`.
//!
//! A runtime directory keeps each program in a directory of its own, named
//! after its exact version, such as `helm-4.3.1/bin/helm`, so two versions of
//! one program can ship side by side. When the directory has a
//! `manifest.json`, that file is the index and Kix reads paths only from it:
//!
//! ```json
//! { "manifestVersion": 1, "system": "x86_64-linux",
//!   "programs": [
//!     { "name": "nix", "version": "2.31.3",
//!       "bin": { "nix": "nix-2.31.3/bin/nix", "nix-store": "nix-2.31.3/bin/nix-store" },
//!       "files": { "nix-2.31.3/bin/nix": { "sha256": "<hex>" },
//!                  "nix-2.31.3/bin/nix-store": { "symlink": "nix" } } }
//! ] }
//! ```
//!
//! `cli/runtime/assemble.py` writes it. Without a manifest, Kix finds the
//! programs by their directory names.
//!
//! The first time Kix uses a runtime with a manifest, it checks that the
//! manifest lists the programs and versions compiled into this binary from
//! `cli/runtime/programs.json`, and stops when it does not. The check reads
//! no file contents, so a user can swap in their own build of a program of
//! the same version. [`verify_files`] checks the contents for `kix doctor`.
//!
//! When `KIX_STORE_ROOT` names a relocated store, [`tool`] also gives the Nix
//! programs an environment that selects that store and ignores the machine's
//! and the user's Nix settings.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use serde::Deserialize;

use crate::eval::store::store_root;

/// The environment variable that names a Kix runtime directory.
pub const RUNTIME_DIR_VAR: &str = "KIX_RUNTIME_DIR";

/// The runtime directory a package of Kix compiles in, read at build time.
const BUILTIN_RUNTIME_DIR: Option<&str> = option_env!("KIX_BUILTIN_RUNTIME_DIR");

/// The file in a runtime directory that lists its programs.
const MANIFEST: &str = "manifest.json";

/// The manifest format this binary reads.
const MANIFEST_VERSION: u32 = 1;

/// The programs and versions this binary expects in its runtime.
const PROGRAMS_JSON: &str = include_str!("../../runtime/programs.json");

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
        "Kix needs {program} {version} exactly, and only a Kix runtime can provide an exact version. Kix found no runtime in {}. Set {RUNTIME_DIR_VAR} to a runtime that ships it",
        searched_text()
    )]
    NoRuntime { program: String, version: String },

    #[error(
        "the Kix runtime in {} ({found_by}) does not belong to this kix binary. It ships {found}, but kix {} expects {expected}. Install bin/kix and libexec/kix from the same Kix release{}",
        dir.display(),
        crate::VERSION,
        if *found_by == FoundBy::Env { format!(", or point {RUNTIME_DIR_VAR} at the runtime of this release") } else { String::new() }
    )]
    Mismatch {
        dir: PathBuf,
        found_by: FoundBy,
        found: String,
        expected: String,
    },

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

/// How Kix found its runtime directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoundBy {
    /// `KIX_RUNTIME_DIR` names it.
    Env,
    /// It is `../libexec/kix/` beside the running binary.
    BesideBinary,
    /// It was compiled in from `KIX_BUILTIN_RUNTIME_DIR`.
    BuiltIn,
}

impl std::fmt::Display for FoundBy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            FoundBy::Env => "named by KIX_RUNTIME_DIR",
            FoundBy::BesideBinary => "beside the kix binary",
            FoundBy::BuiltIn => "compiled into kix",
        })
    }
}

/// The runtime directory Kix uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runtime {
    pub dir: PathBuf,
    pub found_by: FoundBy,
}

/// Return the runtime directory Kix uses, or `None` when it runs programs
/// from `PATH`.
///
/// The first call checks a runtime's manifest against the programs compiled
/// into this binary and fails on a mismatch. Later calls return the same
/// runtime without reading the manifest again.
pub fn runtime() -> Result<Option<Runtime>, RuntimeError> {
    static CHECKED: OnceLock<Option<Runtime>> = OnceLock::new();
    if let Some(found) = CHECKED.get() {
        return Ok(found.clone());
    }
    let found = find(
        std::env::var_os(RUNTIME_DIR_VAR)
            .filter(|d| !d.is_empty())
            .map(PathBuf::from),
        beside_binary(),
        BUILTIN_RUNTIME_DIR.map(PathBuf::from),
    );
    if let Some(rt) = &found {
        check_manifest(rt)?;
    }
    Ok(CHECKED.get_or_init(|| found).clone())
}

/// Return the first runtime directory of `env` (from `KIX_RUNTIME_DIR`),
/// `beside` (beside the binary), and `builtin` (compiled in). `env` counts
/// even without a manifest. The others count only with one.
fn find(
    env: Option<PathBuf>,
    beside: Option<PathBuf>,
    builtin: Option<PathBuf>,
) -> Option<Runtime> {
    if let Some(dir) = env {
        return Some(Runtime {
            dir,
            found_by: FoundBy::Env,
        });
    }
    [(beside, FoundBy::BesideBinary), (builtin, FoundBy::BuiltIn)]
        .into_iter()
        .find_map(|(dir, found_by)| {
            let dir = dir?;
            dir.join(MANIFEST)
                .is_file()
                .then_some(Runtime { dir, found_by })
        })
}

/// Return `../libexec/kix` beside the running binary, with links resolved,
/// so a `kix` linked into another directory still finds its runtime.
fn beside_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    Some(exe.parent()?.parent()?.join("libexec").join("kix"))
}

/// Return the directories Kix searches for a runtime, in order, described
/// for a person.
pub fn searched() -> Vec<String> {
    let mut places = vec![format!("{RUNTIME_DIR_VAR} (not set)")];
    if let Some(dir) = beside_binary() {
        places.push(dir.display().to_string());
    }
    if let Some(dir) = BUILTIN_RUNTIME_DIR {
        places.push(dir.to_string());
    }
    places
}

fn searched_text() -> String {
    searched().join(", ")
}

/// Return the programs and versions this binary expects, from
/// `cli/runtime/programs.json`.
pub fn compiled_in() -> BTreeMap<String, Vec<String>> {
    serde_json::from_str(PROGRAMS_JSON).expect("cli/runtime/programs.json is valid JSON")
}

/// Fail when `rt` has a manifest that lists other programs or versions than
/// this binary expects. A runtime without a manifest is not checked.
fn check_manifest(rt: &Runtime) -> Result<(), RuntimeError> {
    let path = rt.dir.join(MANIFEST);
    if !path.exists() {
        return Ok(());
    }
    let manifest = read_manifest(&rt.dir)?;
    let found = manifest.versions();
    let expected = compiled_in();
    if found == expected {
        return Ok(());
    }
    Err(RuntimeError::Mismatch {
        dir: rt.dir.clone(),
        found_by: rt.found_by,
        found: describe_versions(&found),
        expected: describe_versions(&expected),
    })
}

fn describe_versions(versions: &BTreeMap<String, Vec<String>>) -> String {
    let all: Vec<String> = versions
        .iter()
        .flat_map(|(name, vs)| vs.iter().map(move |v| format!("{name} {v}")))
        .collect();
    if all.is_empty() {
        "no programs".to_string()
    } else {
        all.join(", ")
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
    locate(runtime()?.map(|rt| rt.dir).as_deref(), tool, want)
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

/// The index of a runtime directory, `manifest.json`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    /// The manifest format. Missing in hand-made manifests, which Kix reads
    /// as the current format.
    #[serde(default)]
    pub manifest_version: Option<u32>,
    /// The platform the runtime was built for, such as `x86_64-linux`.
    #[serde(default)]
    pub system: Option<String>,
    pub programs: Vec<ManifestProgram>,
}

/// One version of one program in a runtime directory.
#[derive(Debug, Deserialize)]
pub struct ManifestProgram {
    pub name: String,
    pub version: String,
    /// Each executable's file name, mapped to its path in the runtime
    /// directory.
    pub bin: BTreeMap<String, PathBuf>,
    /// Every file of this program, by its path in the runtime directory.
    #[serde(default)]
    pub files: BTreeMap<PathBuf, ManifestFile>,
}

/// What the manifest records about one file.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum ManifestFile {
    /// A regular file, with the SHA-256 of its contents in hex.
    File { sha256: String },
    /// A symbolic link, with its target.
    Symlink { symlink: PathBuf },
}

impl Manifest {
    /// Return each program's name with its versions, sorted.
    pub fn versions(&self) -> BTreeMap<String, Vec<String>> {
        let mut versions: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for p in &self.programs {
            versions
                .entry(p.name.clone())
                .or_default()
                .push(p.version.clone());
        }
        for vs in versions.values_mut() {
            vs.sort();
        }
        versions
    }
}

/// Read and check the `manifest.json` of the runtime directory `dir`.
pub fn read_manifest(dir: &Path) -> Result<Manifest, RuntimeError> {
    let path = dir.join(MANIFEST);
    let invalid = |message: String| RuntimeError::Manifest {
        path: path.clone(),
        message,
    };
    let bytes = std::fs::read(&path).map_err(|e| invalid(e.to_string()))?;
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|e| invalid(e.to_string()))?;
    if let Some(v) = manifest.manifest_version
        && v != MANIFEST_VERSION
    {
        return Err(invalid(format!(
            "it has format version {v}, and this kix reads version {MANIFEST_VERSION}"
        )));
    }
    for program in &manifest.programs {
        // A path that leaves the runtime directory would run or check a file
        // the runtime does not ship.
        for relative in program.bin.values().chain(program.files.keys()) {
            if !inside(relative) {
                return Err(invalid(format!(
                    "{} {} lists {}, which is not a path inside the runtime directory",
                    program.name,
                    program.version,
                    relative.display()
                )));
            }
        }
    }
    Ok(manifest)
}

fn inside(relative: &Path) -> bool {
    relative.components().next().is_some()
        && relative
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

fn from_manifest(dir: &Path, tool: Tool) -> Result<Vec<Shipped>, RuntimeError> {
    let manifest = read_manifest(dir)?;
    let mut shipped = Vec::new();
    for program in manifest.programs {
        if program.name != tool.program() {
            continue;
        }
        let Some(relative) = program.bin.get(tool.binary()) else {
            continue;
        };
        shipped.push(Shipped {
            version: program.version,
            path: dir.join(relative),
        });
    }
    Ok(shipped)
}

/// A file in a runtime directory that differs from its manifest entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileProblem {
    /// The file's path in the runtime directory.
    pub path: PathBuf,
    /// The program the file belongs to, as `<name> <version>`.
    pub program: String,
    pub problem: String,
}

/// The result of checking every file a manifest lists.
#[derive(Debug, Default)]
pub struct Verification {
    /// How many files the manifest lists.
    pub files: usize,
    pub problems: Vec<FileProblem>,
}

/// Check every file the manifest of `dir` lists against its SHA-256 or link
/// target.
pub fn verify_files(dir: &Path) -> Result<Verification, RuntimeError> {
    let manifest = read_manifest(dir)?;
    let mut result = Verification::default();
    for program in &manifest.programs {
        let label = format!("{} {}", program.name, program.version);
        if program.files.is_empty() {
            result.problems.push(FileProblem {
                path: PathBuf::from(format!("{}-{}", program.name, program.version)),
                program: label.clone(),
                problem: "the manifest lists no files for this program".to_string(),
            });
        }
        for (relative, expected) in &program.files {
            result.files += 1;
            if let Some(problem) = check_file(&dir.join(relative), expected) {
                result.problems.push(FileProblem {
                    path: relative.clone(),
                    program: label.clone(),
                    problem,
                });
            }
        }
    }
    Ok(result)
}

fn check_file(path: &Path, expected: &ManifestFile) -> Option<String> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Some("missing".to_string()),
        Err(e) => return Some(format!("cannot be read: {e}")),
    };
    match expected {
        ManifestFile::Symlink { symlink } => match std::fs::read_link(path) {
            Ok(target) if &target == symlink => None,
            Ok(target) => Some(format!(
                "links to {}, not {}",
                target.display(),
                symlink.display()
            )),
            Err(_) => Some(format!("is not a link to {}", symlink.display())),
        },
        ManifestFile::File { sha256 } => {
            if !meta.is_file() {
                return Some("is not a regular file".to_string());
            }
            match sha256_hex(path) {
                Ok(actual) if actual.eq_ignore_ascii_case(sha256) => None,
                Ok(_) => Some("its SHA-256 differs from the manifest".to_string()),
                Err(e) => Some(format!("cannot be read: {e}")),
            }
        }
    }
}

fn sha256_hex(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
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

    fn write_manifest(dir: &Path, programs: &[(&str, &str)]) {
        let programs: Vec<_> = programs
            .iter()
            .map(|(name, version)| {
                serde_json::json!({
                    "name": name, "version": version,
                    "bin": { *name: format!("{name}-{version}/bin/{name}") },
                })
            })
            .collect();
        std::fs::write(
            dir.join(MANIFEST),
            serde_json::json!({ "manifestVersion": 1, "programs": programs }).to_string(),
        )
        .unwrap();
    }

    #[test]
    fn the_runtime_is_found_in_lookup_order() {
        let env = tempfile::tempdir().unwrap();
        let beside = tempfile::tempdir().unwrap();
        let builtin = tempfile::tempdir().unwrap();
        let some = |d: &tempfile::TempDir| Some(d.path().to_path_buf());

        // KIX_RUNTIME_DIR wins, with or without a manifest.
        let rt = find(some(&env), some(&beside), some(&builtin)).unwrap();
        assert_eq!((rt.dir.as_path(), rt.found_by), (env.path(), FoundBy::Env));

        // The other two count only when they hold a manifest.
        assert_eq!(find(None, some(&beside), some(&builtin)), None);
        write_manifest(builtin.path(), &[]);
        let rt = find(None, some(&beside), some(&builtin)).unwrap();
        assert_eq!(rt.found_by, FoundBy::BuiltIn);
        write_manifest(beside.path(), &[]);
        let rt = find(None, some(&beside), some(&builtin)).unwrap();
        assert_eq!(
            (rt.dir.as_path(), rt.found_by),
            (beside.path(), FoundBy::BesideBinary)
        );
        assert_eq!(find(None, None, None), None);
    }

    /// The programs compiled into kix and the Helm versions the Kix library
    /// renders with come from one commit, so they must agree.
    #[test]
    fn the_compiled_in_helm_versions_match_the_library() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../kix/lib/helm-versions.json");
        let library: BTreeMap<String, String> =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut library: Vec<String> = library.into_values().collect();
        library.sort();
        assert_eq!(compiled_in()["helm"], library);
    }

    #[test]
    fn a_manifest_from_another_release_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let rt = Runtime {
            dir: dir.path().to_path_buf(),
            found_by: FoundBy::BesideBinary,
        };
        // Without a manifest there is nothing to compare.
        check_manifest(&rt).unwrap();

        let expected = compiled_in();
        let all: Vec<(&str, &str)> = expected
            .iter()
            .flat_map(|(n, vs)| vs.iter().map(move |v| (n.as_str(), v.as_str())))
            .collect();
        write_manifest(dir.path(), &all);
        check_manifest(&rt).unwrap();

        let mut other = all.clone();
        other.retain(|(n, _)| *n != "kubectl");
        other.push(("kubectl", "0.0.1"));
        write_manifest(dir.path(), &other);
        let err = check_manifest(&rt).unwrap_err();
        assert!(matches!(err, RuntimeError::Mismatch { .. }), "{err}");
        let text = err.to_string();
        assert!(text.contains("kubectl 0.0.1"), "{text}");
        assert!(text.contains("the same Kix release"), "{text}");
        assert!(!text.contains(RUNTIME_DIR_VAR), "{text}");

        let err = check_manifest(&Runtime {
            found_by: FoundBy::Env,
            ..rt
        })
        .unwrap_err();
        assert!(err.to_string().contains(RUNTIME_DIR_VAR), "{err}");
    }

    #[test]
    fn a_newer_manifest_format_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join(MANIFEST),
            r#"{"manifestVersion": 2, "programs": []}"#,
        )
        .unwrap();
        let err = read_manifest(dir.path()).unwrap_err();
        assert!(err.to_string().contains("format version 2"), "{err}");
    }

    #[test]
    fn verify_files_reports_each_changed_file() {
        let dir = runtime(&[("nix-1/bin", &[])]);
        let bin = dir.path().join("nix-1/bin");
        std::fs::write(bin.join("nix"), "nix").unwrap();
        std::fs::write(bin.join("extra"), "x").unwrap();
        std::os::unix::fs::symlink("nix", bin.join("nix-store")).unwrap();
        let nix_hash = sha256_hex(&bin.join("nix")).unwrap();
        let manifest = |files: serde_json::Value| {
            std::fs::write(
                dir.path().join(MANIFEST),
                serde_json::json!({ "programs": [{
                    "name": "nix", "version": "1",
                    "bin": { "nix": "nix-1/bin/nix" },
                    "files": files,
                }]})
                .to_string(),
            )
            .unwrap();
        };

        manifest(serde_json::json!({
            "nix-1/bin/nix": { "sha256": nix_hash },
            "nix-1/bin/nix-store": { "symlink": "nix" },
        }));
        let ok = verify_files(dir.path()).unwrap();
        assert_eq!((ok.files, ok.problems), (2, vec![]));

        manifest(serde_json::json!({
            "nix-1/bin/nix": { "sha256": "00" },
            "nix-1/bin/nix-store": { "symlink": "other" },
            "nix-1/bin/gone": { "sha256": nix_hash },
            "nix-1/bin/extra": { "symlink": "nix" },
        }));
        let bad = verify_files(dir.path()).unwrap();
        let problems: BTreeMap<_, _> = bad
            .problems
            .iter()
            .map(|p| (p.path.to_str().unwrap(), p.problem.as_str()))
            .collect();
        assert_eq!(
            problems,
            BTreeMap::from([
                ("nix-1/bin/extra", "is not a link to nix"),
                ("nix-1/bin/gone", "missing"),
                ("nix-1/bin/nix", "its SHA-256 differs from the manifest"),
                ("nix-1/bin/nix-store", "links to nix, not other"),
            ])
        );

        manifest(serde_json::json!({ "../outside": { "sha256": nix_hash } }));
        assert!(matches!(
            verify_files(dir.path()).unwrap_err(),
            RuntimeError::Manifest { .. }
        ));
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
