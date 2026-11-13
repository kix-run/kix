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
use crate::project::BuilderKind;
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
    /// Show only Nix's error, without the command line. Set by
    /// [`NixCommandError::brief`] for an evaluation error the reader caused.
    pub brief: bool,
}

impl std::fmt::Display for NixCommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.brief {
            let text = self.stderr.trim();
            return write!(
                f,
                "{}",
                text.strip_prefix("error:").unwrap_or(text).trim_start()
            );
        }
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

/// Return a command that runs `tool`, a Nix program, as this run's Nix
/// runner chooses it ([`runtime::tool`]).
pub(crate) fn command(tool: Tool) -> Result<Command, NixCommandError> {
    runtime::tool(tool, Want::Shipped).map_err(|e: RuntimeError| NixCommandError {
        command: tool.binary().to_string(),
        dir: None,
        status: None,
        stderr: e.to_string(),
        brief: false,
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
            brief: false,
        }
    }

    /// Shorten this error for a reader who did not ask for `-v`: show Nix's
    /// error without the command line, and cut the stack trace to the frames
    /// in the project at `flake_path` ([`shorten_trace`]).
    fn brief(&mut self, flake_path: &Path) {
        self.brief = true;
        self.stderr = shorten_trace(&self.stderr, &project_roots(flake_path));
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
pub fn current_system() -> &'static str {
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

/// The most evaluations [`eval_with_helm`] runs. Each one after the first
/// follows a Helm fetch or render, so this bounds the charts a cluster can
/// render on its first build.
const MAX_EVALUATIONS: usize = 200;

/// Evaluate the `activationIndex` of `cluster_name` and return its store path.
///
/// The index names the Activation record, `kix-packages.json`, and the
/// cluster's other files ([`super::build_files::BuildFiles`]). Each is a
/// `builtins.toFile` path, so evaluation writes them all to the store and
/// nothing is built. [`crate::build_source::Build::of_flake`] then loads and
/// stamps the graph.
///
/// When evaluation stops at a Helm chart that is not in Kix's local store yet,
/// Kix fetches or renders it ([`super::helm`]) and evaluates again.
///
/// `status_fn` is called with progress lines from Nix as they arrive,
/// allowing the caller to update a spinner or progress bar.
pub fn eval_activation_index(
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

    check_library(flake_path, input_overrides)?;

    let flake_ref = format!(".#{}", activation_index_attr(cluster_name));

    tracing::info!(
        cluster = cluster_name,
        flake_ref = %flake_ref,
        flake_path = %flake_path.display(),
        "evaluating cluster activation"
    );

    status_fn(&format!("Evaluating cluster '{cluster_name}'..."));

    match eval_with_helm(flake_path, &[&flake_ref], input_overrides, status_fn) {
        Ok(index) => index_path(cluster_name, &index),
        // Only Nix's wording for a missing flake output. A stack trace says
        // "while evaluating the attribute", so matching looser words turned
        // real evaluation errors into "cluster not found".
        Err(KixEvalError::Nix(e)) if e.missing_attribute() => {
            Err(missing_index(flake_path, cluster_name, input_overrides))
        }
        Err(e) => Err(e),
    }
}

/// Run `nix eval --raw <args>` in `flake_path` and return what it prints.
/// When evaluation stops at a Helm chart that is not in Kix's local store yet,
/// fetch or render it ([`super::helm`]) and evaluate again.
///
/// Under the `nix` builder, Nix renders the charts itself, so this runs
/// `nix eval` once.
pub fn eval_with_helm(
    flake_path: &Path,
    args: &[&str],
    input_overrides: &[(String, String)],
    status_fn: &dyn Fn(&str),
) -> Result<String, KixEvalError> {
    if runtime::nix_runner() == runtime::NixRunner::System {
        let error = match eval_raw(flake_path, args, input_overrides, status_fn)? {
            Ok(stdout) => return Ok(stdout),
            Err(error) => error,
        };
        if let Some(e) = system_eval_error(&error.stderr) {
            return Err(e);
        }
        return Err(failed_evaluation(error, flake_path));
    }
    let mut realised = std::collections::HashSet::new();
    for _ in 0..MAX_EVALUATIONS {
        let error = match eval_raw(flake_path, args, input_overrides, status_fn)? {
            Ok(stdout) => return Ok(stdout),
            Err(error) => error,
        };
        let pending = if error.missing_attribute() {
            Vec::new()
        } else {
            super::helm::pending(&error.stderr)?
        };
        if pending.is_empty() {
            return Err(failed_evaluation(error, flake_path));
        }
        // Check every Helm version before running any, so a project whose
        // library and Kix disagree learns which to move.
        if let Some((wanted, shipped)) = super::helm::unshipped(&pending)? {
            let mismatch = crate::library::HelmMismatch {
                library: crate::library::eval_version(flake_path, input_overrides),
                wanted,
                program: crate::version::running().release(),
                shipped,
            };
            return Err(super::helm::HelmError::LibraryMismatch(Box::new(mismatch)).into());
        }
        for placeholder in pending {
            if !realised.insert(placeholder.out.clone()) {
                return Err(super::helm::HelmError::Stuck {
                    path: placeholder.out,
                }
                .into());
            }
            status_fn(&placeholder.describe());
            super::helm::realise(&placeholder)?;
        }
    }
    Err(KixEvalError::Internal {
        summary: "Helm chart rendering did not finish",
        library: true,
        detail: format!(
            "evaluating {} still requested Helm charts after {MAX_EVALUATIONS} rendering rounds",
            args.join(" ")
        ),
    })
}

/// Return the error for an evaluation that failed for a reason Kix does not
/// handle itself. Errors the Kix library wrote for a person come back from
/// their fields. Any other error is Nix's, shortened unless the reader asked
/// for `-v`.
fn failed_evaluation(mut error: NixCommandError, flake_path: &Path) -> KixEvalError {
    let verbose = tracing::enabled!(tracing::Level::INFO);
    if let Some(mut errors) = super::library_error::parse(&error.stderr) {
        if verbose {
            errors.trace = Some(error.stderr);
        }
        return KixEvalError::Library(errors);
    }
    if !verbose {
        error.brief(flake_path);
    }
    error.into()
}

/// Run `nix eval --raw <args>` in `flake_path`. Return its output, or the
/// failed command, whose stderr may name Helm placeholders.
///
/// The full stack trace is always on. Outside Linux, Nix refuses to build in
/// Kix's local store before it checks a derivation's system, and only the trace
/// names the output of the Helm placeholder it stopped at.
fn eval_raw(
    flake_path: &Path,
    args: &[&str],
    input_overrides: &[(String, String)],
    status_fn: &dyn Fn(&str),
) -> Result<Result<String, NixCommandError>, KixEvalError> {
    let mut cmd = command(Tool::Nix)?;
    cmd.args(["eval", "--raw", "--show-trace"])
        .args(args)
        .args([
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

    let stderr = child.stderr.take().unwrap();
    let mut stderr_lines = Vec::new();
    for line in BufReader::new(stderr).lines() {
        let Ok(line) = line else { continue };
        let trimmed = line.trim();
        if trimmed.starts_with("building") || trimmed.starts_with("copying") {
            status_fn(trimmed);
        }
        stderr_lines.push(line);
    }

    let output = child
        .wait_with_output()
        .map_err(|e| NixCommandError::new(&cmd, None, e.to_string()))?;

    if !output.status.success() {
        return Ok(Err(NixCommandError::new(
            &cmd,
            Some(output.status),
            stderr_lines.join("\n"),
        )));
    }
    Ok(Ok(String::from_utf8_lossy(&output.stdout).into_owned()))
}

/// Explain a failed evaluation under the `nix` builder whose cause Kix
/// knows: the machine's Nix forbids import from derivation, or evaluation
/// reached a Helm placeholder, which the library's nix route never writes.
fn system_eval_error(stderr: &str) -> Option<KixEvalError> {
    if stderr.contains("allow-import-from-derivation") && stderr.contains("disabled") {
        return Some(KixEvalError::ImportFromDerivationDisabled);
    }
    if stderr.contains(super::helm::PLACEHOLDER_SYSTEM) {
        let path = stderr
            .split(|c: char| c.is_whitespace() || "'\"`".contains(c))
            .find(|word| word.starts_with(super::store_path::STORE_DIR))
            .unwrap_or("unknown path")
            .to_string();
        return Some(KixEvalError::PlaceholderUnderNix { path });
    }
    None
}

/// Return the flake attribute under `legacyPackages.<system>` that holds the
/// clusters as this run's builder builds them. The two differ in how Helm
/// charts are rendered.
pub(crate) fn clusters_attr() -> &'static str {
    match runtime::builder() {
        BuilderKind::Nix => "kixClustersNix",
        BuilderKind::Kix | BuilderKind::Remote => "kixClusters",
    }
}

/// Check, once per run, that the project's Kix library read the same
/// builder from `kix.toml` as Kix did ([`crate::project::check_agreement`]),
/// and, unless the project uses a development library, that the library is
/// the running Kix ([`crate::version::policy::check_library`]).
///
/// A library too old to publish its version is left to the checks that
/// catch it later ([`KixEvalError::NoActivationIndex`] and
/// [`crate::library::HelmMismatch`]).
fn check_library(
    flake_path: &Path,
    input_overrides: &[(String, String)],
) -> Result<(), KixEvalError> {
    static AGREED: std::sync::OnceLock<()> = std::sync::OnceLock::new();
    if AGREED.get().is_some() {
        return Ok(());
    }
    let Some(origin) = runtime::builder_source() else {
        return Ok(());
    };
    // Read the lock before Nix evaluates the project, which writes a new
    // lock when `flake.nix` changed. Kix chose its version from this lock
    // before it parsed its arguments and refused a lock it cannot read, so
    // anything but a release here is a development library or a run that
    // skipped the choice.
    let pinned = crate::flake_lock::project_kix(flake_path, input_overrides);
    let facts = library_facts(flake_path, input_overrides)?;
    crate::project::check_agreement(runtime::builder(), &origin, facts.builder.as_deref())?;
    if let Ok(crate::flake_lock::ProjectKix::Release(pinned)) = pinned
        && let Some(library) = facts.version.as_deref().and_then(|v| v.parse().ok())
    {
        crate::version::policy::check_library(crate::version::running(), &pinned, &library)
            .map_err(KixEvalError::LibraryMismatch)?;
    }
    let _ = AGREED.set(());
    Ok(())
}

/// What the project's Kix library publishes about itself.
#[derive(Debug, Default, PartialEq, Eq, serde::Deserialize)]
struct LibraryFacts {
    /// The builder the library read from `kix.toml`.
    builder: Option<String>,
    /// The library's version (`kixLibrary.version`).
    version: Option<String>,
    /// The project's own files, as the library sees them
    /// (`kixLibrary.projectRoot`).
    #[serde(default)]
    project_root: Option<String>,
}

/// The project root the Kix library published in this run, once
/// [`library_facts`] has read it.
static PROJECT_ROOT: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Return the paths under which a stack frame is in the project: the
/// project at `flake_path`, as given and with links resolved, and the copy
/// of it the Kix library reported. Nix names a file of the project by its
/// path in the checkout, and the library knows the copy in Kix's local store.
fn project_roots(flake_path: &Path) -> Vec<String> {
    let mut roots = vec![flake_path.to_string_lossy().into_owned()];
    if let Ok(real) = flake_path.canonicalize() {
        roots.push(real.to_string_lossy().into_owned());
    }
    roots.extend(PROJECT_ROOT.get().cloned());
    roots.retain(|r| r.starts_with('/'));
    roots
}

/// Return the builder the project's Kix library read from `kix.toml` and the
/// library's version, with one evaluation. Each is `None` when the flake does
/// not publish it.
fn library_facts(
    flake_path: &Path,
    input_overrides: &[(String, String)],
) -> Result<LibraryFacts, KixEvalError> {
    let attr = format!(".#legacyPackages.{}", current_system());
    let mut cmd = command(Tool::Nix)?;
    cmd.args([
        "eval",
        "--json",
        &attr,
        "--apply",
        "lp: { builder = lp.kixConfig.builder or null; version = lp.kixLibrary.version or null; project_root = lp.kixLibrary.projectRoot or null; }",
        "--extra-experimental-features",
        "nix-command flakes pipe-operators",
    ]);
    for (name, url) in input_overrides {
        cmd.arg("--override-input").arg(name).arg(url);
    }
    match output(cmd.current_dir(flake_path)) {
        Ok(out) => {
            let facts: LibraryFacts =
                serde_json::from_slice(&out).map_err(|e| KixEvalError::Internal {
                    summary: "could not read the Kix library's settings",
                    library: true,
                    detail: format!("the Kix library's settings are not the expected JSON: {e}"),
                })?;
            if let Some(root) = &facts.project_root {
                let _ = PROJECT_ROOT.set(root.clone());
            }
            Ok(facts)
        }
        Err(e) if e.missing_attribute() => {
            match system_not_provided(".", "legacyPackages", Some(flake_path), input_overrides) {
                Some(err) => Err(err),
                None => Ok(LibraryFacts::default()),
            }
        }
        Err(e) => match system_eval_error(&e.stderr) {
            Some(err) => Err(err),
            None => Err(e.into()),
        },
    }
}

/// The trace frames [`shorten_trace`] keeps, as many as Nix shows without
/// `--show-trace`.
const SHORT_TRACE_FRAMES: usize = 3;

/// Return `stderr` of a Nix evaluation cut down for a reader who did not ask
/// for `-v`.
///
/// It drops Nix's dirty-tree warning and the `trace:` lines the library
/// printed on the way. When the place nearest the error is in the project
/// (under one of `roots`), the error keeps the [`SHORT_TRACE_FRAMES`]
/// project frames nearest to it, which point at the code to change.
/// Otherwise the error was raised in the Kix library, a package, or
/// nixpkgs, whose frames rarely show a reader what to change, so Nix's
/// message stands alone. Text that is not such a trace comes back unchanged.
fn shorten_trace(stderr: &str, roots: &[String]) -> String {
    let lines: Vec<&str> = stderr
        .lines()
        .filter(|l| !l.starts_with("warning: Git tree ") && !l.starts_with("trace: "))
        .collect();
    let Some(first) = lines.iter().position(|l| l.starts_with("error:")) else {
        return stderr.to_string();
    };
    // The innermost error message follows the frames, indented under the
    // first `error:`.
    let Some(last) = lines
        .iter()
        .rposition(|l| l.starts_with(' ') && l.trim_start().starts_with("error:"))
        .filter(|&last| last > first)
    else {
        return lines.join("\n");
    };
    let indent = &lines[last][..lines[last].len() - lines[last].trim_start().len()];
    let message = &lines[last..];
    // Each frame runs from its `…` line to the next one.
    let starts: Vec<usize> = (first..last)
        .filter(|&i| lines[i].trim_start().starts_with('…'))
        .collect();
    let frames: Vec<&[&str]> = starts
        .iter()
        .enumerate()
        .map(|(n, &start)| &lines[start..starts.get(n + 1).copied().unwrap_or(last)])
        .collect();
    let location = |block: &[&str]| -> Option<String> {
        block
            .iter()
            .find_map(|l| l.trim_start().strip_prefix("at "))
            .map(str::to_string)
    };
    // The message names its own place for an error in Nix syntax, such as
    // a missing attribute. A `throw` has its place in the last frame.
    let nearest = location(message).or_else(|| frames.iter().rev().find_map(|f| location(f)));
    let in_project = |at: &str| {
        roots.iter().any(|root| {
            at.strip_prefix(root.as_str())
                .is_some_and(|rest| rest.starts_with('/'))
        })
    };
    if !nearest.as_deref().is_some_and(in_project) {
        let mut alone: Vec<String> = message
            .iter()
            .map(|l| l.strip_prefix(indent).unwrap_or(l).to_string())
            .collect();
        if !frames.is_empty() {
            alone.push(format!(
                "({} stack frame(s) hidden; run with -v to show them)",
                frames.len()
            ));
        }
        return alone.join("\n");
    }
    let kept: Vec<&[&str]> = frames
        .iter()
        .copied()
        .filter(|frame| location(frame).as_deref().is_some_and(in_project))
        .collect();
    let kept = &kept[kept.len().saturating_sub(SHORT_TRACE_FRAMES)..];
    let mut short = vec!["error:".to_string()];
    for frame in kept {
        short.extend(frame.iter().map(|l| l.to_string()));
    }
    if kept.len() < frames.len() {
        short.push(format!(
            "{indent}({} more stack frame(s) hidden; run with -v to show them)",
            frames.len() - kept.len()
        ));
        short.push(String::new());
    }
    short.extend(message.iter().map(|l| l.to_string()));
    short.join("\n")
}

fn index_path(cluster_name: &str, stdout: &str) -> Result<PathBuf, KixEvalError> {
    let index = stdout.trim();
    if !index.starts_with(super::store_path::STORE_DIR) {
        return Err(KixEvalError::StoreGraphError {
            message: format!("evaluation returned {index:?} instead of a store path"),
        });
    }

    let path = PathBuf::from(index);
    tracing::info!(
        cluster = cluster_name,
        path = %path.display(),
        "cluster activation evaluated"
    );
    Ok(path)
}

/// Return the flake attribute that holds the activation index of
/// `cluster_name` on this system.
pub(crate) fn activation_index_attr(cluster_name: &str) -> String {
    format!(
        "legacyPackages.{}.{}.{cluster_name}.activationIndex",
        current_system(),
        clusters_attr()
    )
}

/// Explain why the flake has no `activationIndex` for `cluster_name`: the
/// flake has its outputs for other systems only, the cluster does not
/// exist, or the cluster comes from a Kix library too old to write the
/// index.
fn missing_index(
    flake_path: &Path,
    cluster_name: &str,
    input_overrides: &[(String, String)],
) -> KixEvalError {
    if let Some(e) = system_not_provided(".", "legacyPackages", Some(flake_path), input_overrides) {
        return e;
    }
    let attr = format!(".#legacyPackages.{}.{}", current_system(), clusters_attr());
    let listed = command(Tool::Nix).ok().and_then(|mut cmd| {
        cmd.args([
            "eval",
            &attr,
            "--apply",
            "builtins.attrNames",
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        for (name, url) in input_overrides {
            cmd.arg("--override-input").arg(name).arg(url);
        }
        let out = output(cmd.current_dir(flake_path)).ok()?;
        serde_json::from_slice::<Vec<String>>(&out).ok()
    });
    match listed {
        Some(names) if names.iter().any(|n| n == cluster_name) => KixEvalError::NoActivationIndex {
            cluster: cluster_name.to_string(),
        },
        _ => KixEvalError::not_found(cluster_name),
    }
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
///
/// Format 1 keys the output by full store path. Nix 2.34 and later warn when
/// `--json` comes without a format and plan to refuse it.
pub fn path_info(path: &Path) -> Result<Vec<(String, Vec<String>)>, KixEvalError> {
    let out = output(
        command(Tool::Nix)?
            .args([
                "path-info",
                "--json",
                "--json-format",
                "1",
                "--recursive",
                "--extra-experimental-features",
                "nix-command",
            ])
            .arg(path),
    )?;
    let info: serde_json::Value =
        serde_json::from_slice(&out).map_err(|e| KixEvalError::Internal {
            summary: "could not read build dependency metadata",
            library: false,
            detail: format!("nix path-info printed something other than JSON: {e}"),
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
        serde_json::from_slice(&out).map_err(|e| KixEvalError::Internal {
            summary: "could not read project flake metadata",
            library: false,
            detail: format!("nix flake metadata printed something other than JSON: {e}"),
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

    fn roots() -> Vec<String> {
        vec!["/p".to_string()]
    }

    fn frame(what: &str) -> String {
        frame_at(what, "/p/f.nix")
    }

    fn frame_at(what: &str, at: &str) -> String {
        format!("       … {what}\n         at {at}:1:1:\n            1| x\n")
    }

    #[test]
    fn a_long_trace_keeps_the_frames_nearest_the_error() {
        let full = format!(
            "warning: Git tree '/p' is dirty\ntrace: [kix] warning: no DNS\nerror:\n{}\n{}\n{}\n{}\n       error: boom",
            frame("while evaluating the file"),
            frame("while evaluating the attribute 'y'"),
            frame("while evaluating the attribute 'a'"),
            frame("while calling 'h'"),
        );
        let short = shorten_trace(&full, &roots());
        assert!(
            short.starts_with("error:\n       … while evaluating the attribute 'y'"),
            "{short}"
        );
        assert!(short.contains("(1 more stack frame(s) hidden"), "{short}");
        assert!(!short.contains("while evaluating the file"), "{short}");
        assert!(!short.contains("Git tree"), "{short}");
        assert!(!short.contains("no DNS"), "{short}");
        assert!(short.contains("while calling 'h'"), "{short}");
        assert!(short.ends_with("       error: boom"), "{short}");
    }

    /// A missing attribute in a cluster file names its place in the message.
    /// The frames outside the project go.
    #[test]
    fn frames_outside_the_project_are_hidden() {
        let lib = frame_at("while calling 'mkCluster'", "/x/kix/lib/modules.nix");
        let full = format!(
            "error:\n{}\n{lib}\n       error: attribute 'b' missing\n       at /p/cluster.nix:3:5:\n            3| a.b",
            frame("while evaluating the file"),
        );
        let short = shorten_trace(&full, &roots());
        assert!(!short.contains("kix/lib"), "{short}");
        assert!(short.contains("while evaluating the file"), "{short}");
        assert!(short.contains("(1 more stack frame(s) hidden"), "{short}");
        assert!(short.ends_with("            3| a.b"), "{short}");
    }

    /// A `throw` in a package outside the project shows Nix's message alone,
    /// though the frames of the cluster definition led there.
    #[test]
    fn a_throw_outside_the_project_stands_alone() {
        let pkg = frame_at(
            "while calling 'throw'",
            "«github:kix-run/kix/abc»/kix/packages/experimental/cnpg-database/default.nix",
        );
        let full = format!(
            "error:\n{}\n{pkg}\n       error: app-db: has no `password` dependency.",
            frame("while calling anonymous lambda"),
        );
        assert_eq!(
            shorten_trace(&full, &roots()),
            "error: app-db: has no `password` dependency.\n(2 stack frame(s) hidden; run with -v to show them)"
        );
    }

    /// nixpkgs raises an unknown option, and its message names the option.
    #[test]
    fn an_unknown_option_stands_alone() {
        let full = format!(
            "error:\n{}\n{}\n       error: The option `a.b' does not exist. Definition values:\n       - In `x': 1",
            frame("while calling anonymous lambda"),
            frame_at(
                "while evaluating the module",
                "«github:NixOS/nixpkgs/abc»/lib/modules.nix"
            ),
        );
        assert_eq!(
            shorten_trace(&full, &roots()),
            "error: The option `a.b' does not exist. Definition values:\n- In `x': 1\n(2 stack frame(s) hidden; run with -v to show them)"
        );
    }

    /// A project's own folder named like a Kix folder is still the project,
    /// and a sibling folder whose name starts the same is not.
    #[test]
    fn a_frame_is_in_the_project_by_its_path() {
        let own = frame_at("while calling 'throw'", "/p/kix/packages/site/default.nix");
        let short = shorten_trace(&format!("error:\n{own}\n       error: boom"), &roots());
        assert!(short.contains("/p/kix/packages/site"), "{short}");
        let sibling = frame_at("while calling 'throw'", "/p2/default.nix");
        let short = shorten_trace(&format!("error:\n{sibling}\n       error: boom"), &roots());
        assert!(short.starts_with("error: boom\n(1 stack"), "{short}");
    }

    #[test]
    fn a_short_error_is_left_alone() {
        let text = "error: attribute 'c' missing\n       at «string»:1:24:\n       Did you mean b?";
        assert_eq!(shorten_trace(text, &roots()), text);
        assert_eq!(
            shorten_trace("not a nix error", &roots()),
            "not a nix error"
        );
    }

    /// An error from `kix.fail` comes back as its fields, without the trace.
    #[test]
    fn a_library_error_is_read_from_its_fields() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("flake.nix"),
            r#"{
              outputs = _: let c.kixClusters.c.activationIndex = throw ''
                [K0001] app/web: replicas was removed.
                kix-error/1 {"errors":[{"id":"K0001","instance":"app/web","message":"replicas was removed.","fix":"Set \"replicas\"."}]}''; in {
                legacyPackages = { x86_64-linux = c; aarch64-linux = c; x86_64-darwin = c; aarch64-darwin = c; };
              };
            }"#,
        )
        .unwrap();
        let err = eval_activation_index(dir.path(), "c", &[], &|_| {}).unwrap_err();
        let KixEvalError::Library(errors) = &err else {
            panic!("{err}");
        };
        assert_eq!(errors.errors[0].id.as_deref(), Some("K0001"));
        assert_eq!(
            err.to_string(),
            "[K0001] app/web: replicas was removed.\nFix: Set \"replicas\"."
        );
    }

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
              outputs = _: let c.kixClusters.c.activationIndex = throw "attribute 'root' missing"; in {
                legacyPackages = { x86_64-linux = c; aarch64-linux = c; x86_64-darwin = c; aarch64-darwin = c; };
              };
            }"#,
        )
        .unwrap();
        let build = |cluster| eval_activation_index(dir.path(), cluster, &[], &|_| {});
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
            format!(
                "{{ outputs = _: {{ legacyPackages.{other}.kixClusters.c.activationIndex = null; }}; }}"
            ),
        )
        .unwrap();
        let err = eval_activation_index(dir.path(), "c", &[], &|_| {}).unwrap_err();
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

    /// A flake that provides no `legacyPackages` at all says nothing about
    /// systems, so a missing cluster is still a missing cluster.
    #[test]
    fn a_flake_with_no_packages_has_no_system_to_blame() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("flake.nix"), "{ outputs = _: { }; }").unwrap();
        assert!(matches!(
            eval_activation_index(dir.path(), "c", &[], &|_| {}).unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }

    /// A cluster from a library that writes no activation index is not
    /// reported as missing.
    #[test]
    fn a_cluster_without_an_index_names_the_old_library() {
        let dir = tempfile::tempdir().unwrap();
        let system = current_system();
        std::fs::write(
            dir.path().join("flake.nix"),
            format!("{{ outputs = _: {{ legacyPackages.{system}.kixClusters.c = {{ }}; }}; }}"),
        )
        .unwrap();
        let err = eval_activation_index(dir.path(), "c", &[], &|_| {}).unwrap_err();
        assert!(
            matches!(err, KixEvalError::NoActivationIndex { .. }),
            "{err}"
        );
        assert!(matches!(
            eval_activation_index(dir.path(), "other", &[], &|_| {}).unwrap_err(),
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
