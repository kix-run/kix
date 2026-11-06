//! `nix` and `nix-store` subprocess execution against the Nix store.
//!
//! [`output`] runs a command and converts any failure into a
//! [`NixCommandError`] that records the command line, exit status, and stderr.
//! [`super::cli_backend`] also runs its `nix eval` calls through [`output`].

use std::collections::HashMap;
use std::ffi::OsStr;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

use super::error::KixEvalError;
use super::store_graph::store_name;
use crate::runtime::{self, RuntimeError, Tool, Want};

/// A `nix` or `nix-store` command that did not run, or exited non-zero.
#[derive(Debug)]
pub struct NixCommandError {
    /// The command line, quoted as a shell would need it.
    pub command: String,
    /// The directory it ran in, when that was set.
    pub dir: Option<PathBuf>,
    /// `None` when the command did not start.
    pub status: Option<ExitStatus>,
    /// Its stderr, or why it did not start.
    pub stderr: String,
}

impl std::fmt::Display for NixCommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "`{}`", self.command)?;
        if let Some(dir) = &self.dir {
            write!(f, " in {}", dir.display())?;
        }
        match self.status {
            Some(status) => write!(f, " failed ({status}): {}", self.stderr.trim()),
            None => write!(f, " did not run: {}", self.stderr),
        }
    }
}

impl std::error::Error for NixCommandError {}

/// Return a command that runs `tool`, a Nix program, from the Kix runtime.
pub(crate) fn command(tool: Tool) -> Result<Command, NixCommandError> {
    runtime::tool(tool, Want::Shipped).map_err(|e: RuntimeError| NixCommandError {
        command: tool.binary().to_string(),
        dir: None,
        status: None,
        stderr: e.to_string(),
    })
}

impl NixCommandError {
    fn new(cmd: &Command, status: Option<ExitStatus>, stderr: String) -> Self {
        let quote = |arg: &OsStr| {
            let arg = arg.to_string_lossy();
            let plain = !arg.is_empty()
                && arg
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_./:=@,+%#".contains(c));
            if plain {
                arg.into_owned()
            } else {
                format!("'{}'", arg.replace('\'', r"'\''"))
            }
        };
        Self {
            command: std::iter::once(cmd.get_program())
                .chain(cmd.get_args())
                .map(quote)
                .collect::<Vec<_>>()
                .join(" "),
            dir: cmd.get_current_dir().map(Path::to_path_buf),
            status,
            stderr,
        }
    }

    /// Return whether stderr matches Nix's message for a missing flake attribute.
    pub(crate) fn missing_attribute(&self) -> bool {
        self.stderr.contains("does not provide attribute")
    }
}

/// Run `cmd` and return its stdout, or return a [`NixCommandError`] if it
/// fails to start or exits non-zero.
pub(crate) fn output(cmd: &mut Command) -> Result<Vec<u8>, NixCommandError> {
    let out = cmd
        .output()
        .map_err(|e| NixCommandError::new(cmd, None, e.to_string()))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        return Err(NixCommandError::new(cmd, Some(out.status), stderr));
    }
    Ok(out.stdout)
}

/// Return the Nix system this binary was built for, which is the system Kix
/// looks a flake's outputs up under.
pub(crate) fn current_system() -> &'static str {
    if cfg!(all(target_arch = "x86_64", target_os = "linux")) {
        "x86_64-linux"
    } else if cfg!(all(target_arch = "aarch64", target_os = "linux")) {
        "aarch64-linux"
    } else if cfg!(all(target_arch = "x86_64", target_os = "macos")) {
        "x86_64-darwin"
    } else if cfg!(all(target_arch = "aarch64", target_os = "macos")) {
        "aarch64-darwin"
    } else {
        "x86_64-linux"
    }
}

/// Return the systems `flake` provides the output `flake_output`
/// (`legacyPackages` or `packages`) for, or an empty list when the flake has
/// no such output. `dir` is the working directory for a relative `flake`.
fn provided_systems(
    flake: &str,
    flake_output: &str,
    dir: Option<&Path>,
    input_overrides: &[(String, String)],
) -> Result<Vec<String>, NixCommandError> {
    let mut cmd = command(Tool::Nix)?;
    cmd.args([
        "eval",
        &format!("{flake}#{flake_output}"),
        "--apply",
        "builtins.attrNames",
        "--json",
        "--extra-experimental-features",
        "nix-command flakes pipe-operators",
    ]);
    for (name, url) in input_overrides {
        cmd.arg("--override-input").arg(name).arg(url);
    }
    if let Some(dir) = dir {
        cmd.current_dir(dir);
    }
    let out = match output(&mut cmd) {
        Err(e) if e.missing_attribute() => return Ok(Vec::new()),
        out => out?,
    };
    Ok(serde_json::from_slice(&out).unwrap_or_default())
}

/// Explain a lookup under `flake_output` that Nix said the flake does not
/// provide, when the cause is that the flake provides that output for other
/// systems and not for this binary's. Return `None` when the flake provides
/// it for this system or for no system, or when the check itself fails, so
/// that the caller keeps its own meaning for the missing attribute.
pub(crate) fn system_not_provided(
    flake: &str,
    flake_output: &str,
    dir: Option<&Path>,
    input_overrides: &[(String, String)],
) -> Option<KixEvalError> {
    let provided = match provided_systems(flake, flake_output, dir, input_overrides) {
        Ok(provided) => provided,
        Err(e) => {
            tracing::debug!(error = %e, "could not list the systems the flake provides");
            return None;
        }
    };
    let system = current_system();
    if provided.is_empty() || provided.iter().any(|s| s == system) {
        return None;
    }
    Some(KixEvalError::SystemNotProvided {
        system: system.to_string(),
        provided,
    })
}

/// Return a Nix system that is not the one the tests run on.
#[cfg(test)]
pub(crate) fn other_system() -> &'static str {
    if current_system() == "aarch64-darwin" {
        "x86_64-linux"
    } else {
        "aarch64-darwin"
    }
}

/// Build `cluster-<name>-activation` and return the result store path.
///
/// The result folder holds `activation`, a link to the Activation
/// resource's store path, and `kix-packages.json`, the index of packages to
/// resource store paths. [`crate::build_source::Build::of_flake`] then loads
/// and stamps the graph.
///
/// `status_fn` is called with nix build progress lines as they arrive,
/// allowing the caller to update a spinner or progress bar.
pub(crate) fn build_cluster_activation(
    flake_path: &Path,
    cluster_name: &str,
    input_overrides: &[(String, String)],
    status_fn: &dyn Fn(&str),
) -> Result<PathBuf, KixEvalError> {
    if !cluster_name
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err(KixEvalError::not_found(cluster_name));
    }

    let flake_ref = format!(".#cluster-{}-activation", cluster_name);

    tracing::info!(
        cluster = cluster_name,
        flake_ref = %flake_ref,
        flake_path = %flake_path.display(),
        "building cluster activation"
    );

    status_fn(&format!("Evaluating cluster '{cluster_name}'..."));

    let mut cmd = command(Tool::Nix)?;
    cmd.args([
        "build",
        &flake_ref,
        "--no-link",
        "--print-out-paths",
        "--extra-experimental-features",
        "nix-command flakes pipe-operators",
    ]);
    for (name, url) in input_overrides {
        cmd.arg("--override-input").arg(name).arg(url);
    }
    cmd.current_dir(flake_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| NixCommandError::new(&cmd, None, e.to_string()))?;

    // Stream stderr to update progress
    let stderr = child.stderr.take().unwrap();
    let stderr_reader = BufReader::new(stderr);
    let mut stderr_lines = Vec::new();

    for line in stderr_reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Show the latest Nix build progress line from stderr.
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            // Extract meaningful progress from nix output
            if trimmed.starts_with("building") || trimmed.starts_with("copying") {
                status_fn(trimmed);
            } else if trimmed.contains("evaluating") {
                status_fn(&format!("Evaluating '{cluster_name}'..."));
            } else if trimmed.starts_with("this derivation") {
                status_fn(&format!("Building '{cluster_name}'..."));
            }
        }
        stderr_lines.push(line);
    }

    let output = child
        .wait_with_output()
        .map_err(|e| NixCommandError::new(&cmd, None, e.to_string()))?;

    if !output.status.success() {
        let error = NixCommandError::new(&cmd, Some(output.status), stderr_lines.join("\n"));
        // Only Nix's wording for a missing flake output. A stack trace says
        // "while evaluating the attribute", so matching looser words turned
        // real evaluation errors into "cluster not found".
        if error.missing_attribute() {
            return Err(
                system_not_provided(".", "packages", Some(flake_path), input_overrides)
                    .unwrap_or_else(|| KixEvalError::not_found(cluster_name)),
            );
        }
        return Err(error.into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let result_path = stdout.trim();
    if result_path.is_empty() {
        return Err(KixEvalError::StoreGraphError {
            message: "nix build produced no output path".to_string(),
        });
    }

    let path = PathBuf::from(result_path);
    tracing::info!(
        cluster = cluster_name,
        path = %path.display(),
        "activation built"
    );
    Ok(path)
}

/// Map every path in the closure of `root_path` that refers to other paths
/// to those paths, leaving out a path's reference to itself.
///
/// Propagates subprocess failures rather than returning an empty graph, which
/// would cause a plan to treat all live resources as orphans.
pub(crate) fn closure_graph(
    root_path: &Path,
) -> Result<HashMap<PathBuf, Vec<PathBuf>>, KixEvalError> {
    Ok(references_graph(path_info(root_path)?))
}

fn references_graph(info: Vec<(String, Vec<String>)>) -> HashMap<PathBuf, Vec<PathBuf>> {
    let mut deps = HashMap::new();
    for (path, references) in info {
        let mut refs: Vec<PathBuf> = references
            .into_iter()
            .filter(|r| *r != path)
            .map(PathBuf::from)
            .collect();
        if refs.is_empty() {
            continue;
        }
        refs.sort_by(|a, b| {
            store_name(a)
                .to_lowercase()
                .cmp(&store_name(b).to_lowercase())
        });
        deps.insert(PathBuf::from(path), refs);
    }
    deps
}

/// Query every path in the closure of `path` and its references via
/// `nix path-info --json --recursive`.
pub fn path_info(path: &Path) -> Result<Vec<(String, Vec<String>)>, KixEvalError> {
    let out = output(
        command(Tool::Nix)?
            .args([
                "path-info",
                "--json",
                "--recursive",
                "--extra-experimental-features",
                "nix-command",
            ])
            .arg(path),
    )?;
    let info: serde_json::Value =
        serde_json::from_slice(&out).map_err(|e| KixEvalError::StoreGraphError {
            message: format!("nix path-info printed something other than JSON: {e}"),
        })?;
    Ok(path_info_references(&info))
}

/// Extract `(path, references)` pairs from `nix path-info --json` output,
/// supporting both the object format (Nix 2.19+) and the legacy array format.
fn path_info_references(info: &serde_json::Value) -> Vec<(String, Vec<String>)> {
    let refs = |v: &serde_json::Value| -> Vec<String> {
        v.get("references")
            .and_then(|r| r.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    };
    match info {
        serde_json::Value::Object(map) => map.iter().map(|(p, v)| (p.clone(), refs(v))).collect(),
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|v| Some((v.get("path")?.as_str()?.to_string(), refs(v))))
            .collect(),
        _ => Vec::new(),
    }
}

/// Register `link` as a Nix GC root for `target` with `nix-store --add-root`.
pub(crate) fn add_gc_root(link: &Path, target: &Path) -> Result<(), NixCommandError> {
    output(
        command(Tool::NixStore)?
            .arg("--add-root")
            .arg(link)
            .arg("--realise")
            .arg(target),
    )
    .map(drop)
}

/// The commit a flake's source comes from, as `nix flake metadata` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlakeRevision {
    /// The commit `HEAD` points at.
    pub rev: String,
    /// Whether tracked files differ from `rev`. Nix leaves untracked files
    /// out of a Git flake, so they do not count.
    pub dirty: bool,
}

/// Return the commit of the Git checkout that holds the flake in
/// `flake_dir`. Return `None` for a flake outside Git or in a repository
/// with no commit.
pub fn flake_revision(flake_dir: &Path) -> Result<Option<FlakeRevision>, KixEvalError> {
    let out = output(
        command(Tool::Nix)?
            .args([
                "flake",
                "metadata",
                "--json",
                "--no-write-lock-file",
                "--extra-experimental-features",
                "nix-command flakes",
            ])
            .arg(flake_dir),
    )?;
    let metadata: serde_json::Value =
        serde_json::from_slice(&out).map_err(|e| KixEvalError::StoreGraphError {
            message: format!("nix flake metadata printed something other than JSON: {e}"),
        })?;
    Ok(revision_of(&metadata))
}

fn revision_of(metadata: &serde_json::Value) -> Option<FlakeRevision> {
    let text = |key: &str| metadata.get(key).and_then(serde_json::Value::as_str);
    if let Some(rev) = text("revision") {
        return Some(FlakeRevision {
            rev: rev.to_string(),
            dirty: false,
        });
    }
    let rev = text("dirtyRevision")?.strip_suffix("-dirty")?;
    Some(FlakeRevision {
        rev: rev.to_string(),
        dirty: true,
    })
}

/// Return the output of `nix --version`, or `None` if `nix` cannot be run.
pub fn version() -> Option<String> {
    let out = output(command(Tool::Nix).ok()?.arg("--version")).ok()?;
    String::from_utf8(out).ok().map(|s| s.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_graph_query_that_fails_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let err = closure_graph(dir.path()).unwrap_err();
        assert!(err.to_string().contains("nix path-info"), "{err}");
    }

    /// Only paths with references other than themselves get an entry, and
    /// each list is in name order.
    #[test]
    fn the_graph_leaves_out_self_references() {
        let p = |s: &str| format!("/nix/store/{:0>32}-{s}", s.len());
        let graph = references_graph(vec![
            (p("a"), vec![p("a"), p("zz"), p("bbb")]),
            (p("bbb"), vec![p("bbb")]),
            (p("zz"), vec![]),
        ]);
        assert_eq!(
            graph,
            HashMap::from([(PathBuf::from(p("a")), vec![p("bbb").into(), p("zz").into()])])
        );
    }

    #[test]
    fn a_failure_names_the_command_its_status_and_stderr() {
        let dir = tempfile::tempdir().unwrap();
        let err = output(
            Command::new("sh")
                .args(["-c", "echo out; echo broke >&2; exit 3"])
                .current_dir(dir.path()),
        )
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            format!(
                "`sh -c 'echo out; echo broke >&2; exit 3'` in {} failed (exit status: 3): broke",
                dir.path().display()
            )
        );

        let err = output(&mut Command::new("/nonexistent/nix")).unwrap_err();
        assert!(
            err.to_string()
                .starts_with("`/nonexistent/nix` did not run: "),
            "{err}"
        );
    }

    /// The command line pastes into a shell as it ran.
    #[test]
    fn an_argument_a_shell_would_split_is_quoted() {
        let mut cmd = Command::new("nix");
        cmd.args(["build", ".#c", "git+https://h/r?ref=a&rev=b", "it's", ""]);
        assert_eq!(
            NixCommandError::new(&cmd, None, String::new()).command,
            r"nix build .#c 'git+https://h/r?ref=a&rev=b' 'it'\''s' ''"
        );
    }

    /// A cluster whose evaluation fails is not reported as missing, though
    /// Nix's stack trace says "attribute" and the error says "missing".
    #[test]
    fn an_evaluation_error_is_not_a_missing_cluster() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("flake.nix"),
            r#"{
              outputs = _: let c.cluster-c-activation = throw "attribute 'root' missing"; in {
                packages = { x86_64-linux = c; aarch64-linux = c; x86_64-darwin = c; aarch64-darwin = c; };
              };
            }"#,
        )
        .unwrap();
        let build = |cluster| build_cluster_activation(dir.path(), cluster, &[], &|_| {});
        let err = build("c").unwrap_err();
        assert!(matches!(err, KixEvalError::Nix(_)), "{err}");
        assert!(
            err.to_string().contains("attribute 'root' missing"),
            "{err}"
        );
        assert!(matches!(
            build("other").unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }

    /// A flake that provides its outputs for other systems only is reported
    /// as such, naming this system and the systems it has, not as a missing
    /// cluster.
    #[test]
    fn a_flake_for_other_systems_names_them() {
        let dir = tempfile::tempdir().unwrap();
        let other = other_system();
        std::fs::write(
            dir.path().join("flake.nix"),
            format!("{{ outputs = _: {{ packages.{other}.cluster-c-activation = null; }}; }}"),
        )
        .unwrap();
        let err = build_cluster_activation(dir.path(), "c", &[], &|_| {}).unwrap_err();
        match &err {
            KixEvalError::SystemNotProvided { system, provided } => {
                assert_eq!(system, current_system());
                assert_eq!(provided, &[other.to_string()]);
            }
            e => panic!("{e}"),
        }
        let msg = err.to_string();
        assert!(
            msg.contains(&format!(
                "systems = [ \"{other}\" \"{}\" ]",
                current_system()
            )),
            "{msg}"
        );
    }

    /// A flake that provides no `packages` at all says nothing about
    /// systems, so a missing cluster is still a missing cluster.
    #[test]
    fn a_flake_with_no_packages_has_no_system_to_blame() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("flake.nix"), "{ outputs = _: { }; }").unwrap();
        assert!(matches!(
            build_cluster_activation(dir.path(), "c", &[], &|_| {}).unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }

    #[test]
    fn a_flake_revision_is_clean_dirty_or_absent() {
        let rev = "0b88f978a1ed669ea9f12b63605c8101d2f48fcd";
        assert_eq!(
            revision_of(&json!({"revision": rev, "dirtyRevision": null})),
            Some(FlakeRevision {
                rev: rev.into(),
                dirty: false
            })
        );
        assert_eq!(
            revision_of(&json!({"revision": null, "dirtyRevision": format!("{rev}-dirty")})),
            Some(FlakeRevision {
                rev: rev.into(),
                dirty: true
            })
        );
        // A path flake, or a repository with no commit.
        assert_eq!(revision_of(&json!({"url": "path:/x"})), None);
        assert_eq!(
            revision_of(&json!({"revision": null, "dirtyRevision": null})),
            None
        );
    }

    #[test]
    fn path_info_in_either_shape() {
        let refs = vec!["/nix/store/b".to_string()];
        let new = json!({"/nix/store/a": {"references": ["/nix/store/b"]}});
        let old = json!([{"path": "/nix/store/a", "references": ["/nix/store/b"]}]);
        for info in [new, old] {
            assert_eq!(
                path_info_references(&info),
                vec![("/nix/store/a".to_string(), refs.clone())]
            );
        }
    }
}
