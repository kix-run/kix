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

    let mut cmd = Command::new("nix");
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
            return Err(KixEvalError::not_found(cluster_name));
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

/// Query the direct references of every path in the closure of `root_path`
/// via `nix-store -q --graph`.
///
/// Propagates subprocess failures rather than returning an empty graph, which
/// would cause a plan to treat all live resources as orphans.
pub(crate) fn closure_graph(
    root_path: &Path,
) -> Result<HashMap<PathBuf, Vec<PathBuf>>, NixCommandError> {
    let out = output(
        Command::new("nix-store")
            .args(["-q", "--graph"])
            .arg(root_path),
    )?;

    let stdout = String::from_utf8_lossy(&out);
    let nix_store = "/nix/store/";
    let mut deps: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

    for line in stdout.lines() {
        let line = line.trim();
        if !line.contains("->") {
            continue;
        }
        let Some((src_part, dst_part)) = line.split_once("->") else {
            continue;
        };
        let src_base = src_part.trim().trim_matches('"').trim();
        let dst_base = dst_part
            .split('[')
            .next()
            .unwrap_or("")
            .trim()
            .trim_matches('"')
            .trim()
            .trim_end_matches(';');

        if src_base.is_empty() || dst_base.is_empty() {
            continue;
        }

        let src = PathBuf::from(format!("{nix_store}{src_base}"));
        let dst = PathBuf::from(format!("{nix_store}{dst_base}"));

        // DOT edges point from dependency to dependent, so invert them to map
        // each path to its dependencies.
        deps.entry(dst).or_default().push(src);
    }

    for refs in deps.values_mut() {
        refs.sort_by(|a, b| {
            store_name(a)
                .to_lowercase()
                .cmp(&store_name(b).to_lowercase())
        });
    }

    Ok(deps)
}

/// Query every path in the closure of `path` and its references via
/// `nix path-info --json --recursive`.
pub fn path_info(path: &Path) -> Result<Vec<(String, Vec<String>)>, KixEvalError> {
    let out = output(
        Command::new("nix")
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
        Command::new("nix-store")
            .arg("--add-root")
            .arg(link)
            .arg("--realise")
            .arg(target),
    )
    .map(drop)
}

/// Return the output of `nix --version`, or `None` if `nix` cannot be run.
pub fn version() -> Option<String> {
    let out = output(Command::new("nix").arg("--version")).ok()?;
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
        assert!(err.to_string().contains("nix-store -q --graph"), "{err}");
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
