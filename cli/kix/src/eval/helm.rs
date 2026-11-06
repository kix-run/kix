//! Fetch and render the Helm charts an evaluation stopped at.
//!
//! `kix/lib/helm.nix` turns a chart fetch and a chart render into
//! placeholder derivations of system `kix-helm`. No Nix can build them, so
//! an evaluation that reads one stops with an error. Depending on the
//! platform, the error and its `--show-trace` stack trace name either the
//! `.drv` or only its output. [`pending`] takes every store path the text
//! names, asks the store for the derivers of the ones that are not `.drv`
//! files, and keeps the placeholders among them. It then runs the Helm release each
//! spec names, writes the output into Kix's store under the path the
//! derivation fixes, and registers it there. The next evaluation reads it.
//!
//! A render's output is registered with its real NAR hash, so
//! `nix store verify` accepts it. A fetched chart goes in with
//! `nix-store --add-fixed`, which puts it at the derivation's path only
//! when its hash is the one the package states.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use base64::Engine as _;
use serde::Deserialize;
use sha2::Digest as _;

use super::derivation::{self, Derivation};
use super::nix::{NixCommandError, command, output};
use super::store::real_path;
use crate::runtime::{self, RuntimeError, Tool, Want};

/// The `system` of a placeholder derivation.
pub const PLACEHOLDER_SYSTEM: &str = "kix-helm";

/// The render and fetch spec version this binary reads. `kix/lib/helm.nix`
/// writes it, and changes it when the meaning of a spec or of a render's
/// output changes.
const SPEC_VERSION: u64 = 1;

/// Why Kix could not fetch or render a chart.
#[derive(Debug, thiserror::Error)]
pub enum HelmError {
    #[error(
        "This cluster's Kix library renders Helm charts with Helm {wanted}, but this kix binary ships {}. Update the kix input in flake.lock, or use the kix binary of the same version as the library",
        shipped_text(shipped)
    )]
    VersionNotShipped {
        wanted: String,
        shipped: Vec<String>,
    },

    #[error(transparent)]
    LibraryMismatch(Box<crate::library::HelmMismatch>),

    #[error(
        "this cluster's Kix library writes Helm specs of version {found}, and this kix binary reads version {SPEC_VERSION}. Run `kix lib update` to move flake.lock to this kix release, or use the kix binary of the same version as the library"
    )]
    SpecVersion { found: u64 },

    #[error("could not run Helm {version}: {source}")]
    Runtime {
        version: String,
        #[source]
        source: RuntimeError,
    },

    #[error("`helm template` of the chart {release} failed: {stderr}")]
    Template { release: String, stderr: String },

    #[error(
        "could not convert the output of `helm template` for the chart {release} to JSON: {source}"
    )]
    Yaml {
        release: String,
        #[source]
        source: super::helm_yaml::YamlError,
    },

    #[error("could not pull the Helm chart {chart}: {stderr}")]
    Pull { chart: String, stderr: String },

    #[error(
        "the Helm chart {chart} has the hash {found}, but the package expects {expected}. Check `hash` in the package, or whether the chart was published again under the same version"
    )]
    HashMismatch {
        chart: String,
        expected: String,
        found: String,
    },

    #[error("could not read the Helm placeholder {}: {message}", drv.display())]
    Spec { drv: PathBuf, message: String },

    #[error(transparent)]
    Derivation(#[from] derivation::DerivationError),

    #[error(transparent)]
    Nix(#[from] NixCommandError),

    #[error("could not write {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error(
        "evaluation still needs {} after Kix wrote it to the local store ({}). Remove Kix's local store directory and run the command again",
        path.display(),
        super::store::store_root().display()
    )]
    Stuck { path: PathBuf },
}

fn shipped_text(shipped: &[String]) -> String {
    match shipped {
        [] => "no Helm".to_string(),
        versions => format!("Helm {}", versions.join(" and ")),
    }
}

/// A placeholder derivation whose output is not in the store yet.
#[derive(Debug)]
pub struct Placeholder {
    pub drv: PathBuf,
    pub out: PathBuf,
    job: Job,
}

#[derive(Debug)]
enum Job {
    Render(RenderSpec),
    Fetch {
        spec: FetchSpec,
        algo: String,
        hash_hex: String,
    },
}

/// What `helmTemplateDerivation` in `kix/lib/helm.nix` asks Kix to run.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenderSpec {
    helm: String,
    chart: PathBuf,
    release_name: String,
    namespace: Option<String>,
    include_crds: bool,
    include_hooks: bool,
    kube_version: Option<String>,
    extra_flags: Vec<String>,
    /// The values file's JSON text, passed to Helm as Nix wrote it.
    values: String,
}

/// What `fetchHelmChart` in `kix/lib/helm.nix` asks Kix to pull.
#[derive(Debug, Deserialize)]
struct FetchSpec {
    helm: String,
    repo: String,
    name: String,
    version: String,
}

impl Placeholder {
    /// Describe the work for a progress line.
    pub fn describe(&self) -> String {
        match &self.job {
            Job::Render(spec) => format!(
                "Rendering Helm chart '{}' with Helm {}...",
                spec.release_name, spec.helm
            ),
            Job::Fetch { spec, .. } => {
                format!("Fetching Helm chart {} {}...", spec.name, spec.version)
            }
        }
    }
}

/// Return the placeholders that `stderr`, the error output of a failed
/// evaluation, names and that have no output yet, fetches before renders.
/// An empty list means the evaluation failed for another reason.
///
/// This reads no wording from the error. Every store path in it is a
/// candidate, and only a derivation of system [`PLACEHOLDER_SYSTEM`]
/// counts.
pub fn pending(stderr: &str) -> Result<Vec<Placeholder>, HelmError> {
    let (mut queue, outputs): (Vec<PathBuf>, Vec<PathBuf>) = store_paths(stderr)
        .into_iter()
        .partition(|p| p.as_os_str().to_string_lossy().ends_with(".drv"));
    queue.extend(derivers(&outputs));
    let mut seen = std::collections::HashSet::new();
    let mut found = Vec::new();
    while let Some(drv_path) = queue.pop() {
        if !seen.insert(drv_path.clone()) || !real_path(&drv_path).is_file() {
            continue;
        }
        let drv = derivation::read(&drv_path)?;
        if drv.system != PLACEHOLDER_SYSTEM {
            continue;
        }
        // A render's chart is an input derivation, which the error may
        // not name when Nix stops at the render.
        queue.extend(drv.input_drvs.iter().cloned());
        found.push(placeholder(&drv_path, drv)?);
    }
    let invalid = invalid_paths(found.iter().map(|p| p.out.as_path()))?;
    let mut pending: Vec<Placeholder> = found
        .into_iter()
        .filter(|p| invalid.contains(&p.out))
        .collect();
    pending.sort_by_key(|p| (matches!(p.job, Job::Render(_)), p.out.clone()));
    Ok(pending)
}

/// Return every store path in `text` in Nix's logical form, in order of
/// first mention.
///
/// A stack trace may print a path under the store's real location, such as
/// `/Users/a/Library/Caches/kix/store/nix/store/<hash>-<name>`. The logical
/// path starts at the store directory. A path into a store object, such as
/// `<hash>-source/lib/helm.nix`, yields the object itself.
fn store_paths(text: &str) -> Vec<PathBuf> {
    let prefix = format!("{}/", super::store_path::STORE_DIR);
    let name_char = |c: char| c.is_ascii_alphanumeric() || "+-._?=".contains(c);
    let mut paths: Vec<PathBuf> = Vec::new();
    for (start, _) in text.match_indices(&prefix) {
        let tail = &text[start + prefix.len()..];
        let end = tail.find(|c: char| !name_char(c)).unwrap_or(tail.len());
        let candidate = format!("{prefix}{}", &tail[..end]);
        if super::store_path::name_of(&candidate).is_none() {
            continue;
        }
        let path = PathBuf::from(candidate);
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    paths
}

/// Return the derivations in Kix's store that produce `outputs`. A path with
/// no known deriver adds nothing.
///
/// A failure here only means Kix finds no placeholder through these paths,
/// so it is logged, and the caller reports the evaluation error instead.
fn derivers(outputs: &[PathBuf]) -> Vec<PathBuf> {
    if outputs.is_empty() {
        return Vec::new();
    }
    let result = command(Tool::NixStore)
        .and_then(|mut cmd| output(cmd.args(["--query", "--valid-derivers"]).args(outputs)));
    match result {
        Ok(out) => String::from_utf8_lossy(&out)
            .lines()
            .map(str::trim)
            .filter(|l| l.ends_with(".drv"))
            .map(PathBuf::from)
            .collect(),
        Err(error) => {
            tracing::warn!(%error, "could not look up the Helm charts behind paths in an evaluation error; Kix will report the evaluation error as-is");
            Vec::new()
        }
    }
}

fn placeholder(drv_path: &Path, drv: Derivation) -> Result<Placeholder, HelmError> {
    let bad = |message: String| HelmError::Spec {
        drv: drv_path.to_path_buf(),
        message,
    };
    let out = drv
        .outputs
        .get("out")
        .ok_or_else(|| bad("it has no output named out".into()))?
        .clone();
    let read_version = |json: &str| -> Result<(), HelmError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Versioned {
            spec_version: u64,
        }
        let v: Versioned = serde_json::from_str(json).map_err(|e| bad(e.to_string()))?;
        if v.spec_version != SPEC_VERSION {
            return Err(HelmError::SpecVersion {
                found: v.spec_version,
            });
        }
        Ok(())
    };
    let job = if let Some(json) = drv.env.get("kixHelmSpec") {
        read_version(json)?;
        Job::Render(serde_json::from_str(json).map_err(|e| bad(e.to_string()))?)
    } else if let Some(json) = drv.env.get("kixHelmFetch") {
        read_version(json)?;
        Job::Fetch {
            spec: serde_json::from_str(json).map_err(|e| bad(e.to_string()))?,
            algo: out.hash_algo.clone(),
            hash_hex: out.hash.clone(),
        }
    } else {
        return Err(bad("it has neither kixHelmSpec nor kixHelmFetch".into()));
    };
    Ok(Placeholder {
        drv: drv_path.to_path_buf(),
        out: out.path,
        job,
    })
}

/// Return the paths among `paths` that are not valid in the store.
fn invalid_paths<'a>(
    paths: impl Iterator<Item = &'a Path>,
) -> Result<std::collections::HashSet<PathBuf>, HelmError> {
    let paths: Vec<&Path> = paths.collect();
    if paths.is_empty() {
        return Ok(Default::default());
    }
    let out = output(
        command(Tool::NixStore)?
            .args(["--check-validity", "--print-invalid"])
            .args(&paths),
    )?;
    Ok(String::from_utf8_lossy(&out)
        .lines()
        .map(|l| PathBuf::from(l.trim()))
        .collect())
}

/// Return a Helm version that `pending` asks for and the Kix runtime does
/// not ship, with the versions it does ship. Return `None` when it ships
/// every one.
pub fn unshipped(pending: &[Placeholder]) -> Result<Option<(String, Vec<String>)>, HelmError> {
    let mut wanted: Vec<&str> = pending
        .iter()
        .map(|p| match &p.job {
            Job::Render(spec) => spec.helm.as_str(),
            Job::Fetch { spec, .. } => spec.helm.as_str(),
        })
        .collect();
    let Some(first) = wanted.first().map(|v| v.to_string()) else {
        return Ok(None);
    };
    wanted.sort();
    wanted.dedup();
    let shipped = runtime::shipped_versions(Tool::Helm).map_err(|source| HelmError::Runtime {
        version: first,
        source,
    })?;
    Ok(wanted
        .into_iter()
        .find(|w| !shipped.iter().any(|s| s == w))
        .map(|w| (w.to_string(), shipped)))
}

/// Fetch or render `placeholder` and put its output into the store.
pub fn realise(placeholder: &Placeholder) -> Result<(), HelmError> {
    let _lock = lock(&placeholder.out)?;
    if invalid_paths(std::iter::once(placeholder.out.as_path()))?.is_empty() {
        return Ok(());
    }
    match &placeholder.job {
        Job::Render(spec) => {
            let json = render(spec)?;
            register(&placeholder.out, &placeholder.drv, json.as_bytes())
        }
        Job::Fetch {
            spec,
            algo,
            hash_hex,
        } => fetch(spec, algo, hash_hex, &placeholder.out),
    }
}

/// Return a command that runs the exact Helm release `version` with an
/// environment of its own, so the user's Helm settings and repositories
/// do not change what it does.
fn helm(version: &str, home: &Path) -> Result<Command, HelmError> {
    let mut cmd = runtime::tool(Tool::Helm, Want::Exact(version)).map_err(|e| match e {
        RuntimeError::NoSuchVersion { shipped, .. } => HelmError::VersionNotShipped {
            wanted: version.to_string(),
            shipped,
        },
        source => HelmError::Runtime {
            version: version.to_string(),
            source,
        },
    })?;
    cmd.env_clear()
        .env("HOME", home)
        .env("HELM_CACHE_HOME", home.join("cache"))
        .env("HELM_CONFIG_HOME", home.join("config"))
        .env("HELM_DATA_HOME", home.join("data"));
    Ok(cmd)
}

/// Run `helm template` as `spec` asks and return its output as JSON.
fn render(spec: &RenderSpec) -> Result<String, HelmError> {
    let tmp = tempdir()?;
    let values = tmp.path().join("values.json");
    std::fs::write(&values, &spec.values).map_err(|source| HelmError::Io {
        path: values.clone(),
        source,
    })?;
    let mut cmd = helm(&spec.helm, tmp.path())?;
    cmd.arg("template")
        .arg(&spec.release_name)
        .arg(real_path(&spec.chart))
        .arg("--values")
        .arg(&values);
    if let Some(namespace) = &spec.namespace {
        cmd.args(["--namespace", namespace]);
    }
    if spec.include_crds {
        cmd.arg("--include-crds");
    }
    if !spec.include_hooks {
        cmd.arg("--no-hooks");
    }
    if let Some(kube_version) = &spec.kube_version {
        cmd.args(["--kube-version", kube_version]);
    }
    cmd.args(&spec.extra_flags).current_dir(tmp.path());
    tracing::info!(release = %spec.release_name, helm = %spec.helm, chart = %spec.chart.display(), "rendering Helm chart");
    let out = cmd.output().map_err(|e| HelmError::Template {
        release: spec.release_name.clone(),
        stderr: e.to_string(),
    })?;
    if !out.status.success() {
        return Err(HelmError::Template {
            release: spec.release_name.clone(),
            stderr: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }
    let yaml = String::from_utf8_lossy(&out.stdout);
    super::helm_yaml::to_json(&yaml).map_err(|source| HelmError::Yaml {
        release: spec.release_name.clone(),
        source,
    })
}

/// Pull the chart `spec` names, check it against the hash the derivation
/// fixes, and add it to the store at `out`.
fn fetch(spec: &FetchSpec, algo: &str, hash_hex: &str, out: &Path) -> Result<(), HelmError> {
    let chart = format!("{} {} from {}", spec.name, spec.version, spec.repo);
    let tmp = tempdir()?;
    let dest = tmp.path().join("pull");
    std::fs::create_dir(&dest).map_err(|source| HelmError::Io {
        path: dest.clone(),
        source,
    })?;
    let mut cmd = helm(&spec.helm, tmp.path())?;
    // A pull needs the network, so it keeps the proxy and certificate
    // settings that `helm` would otherwise lose with the environment.
    for (key, value) in std::env::vars_os() {
        let key_text = key.to_string_lossy();
        if matches!(
            key_text.to_ascii_uppercase().as_str(),
            "HTTP_PROXY" | "HTTPS_PROXY" | "NO_PROXY" | "SSL_CERT_FILE" | "SSL_CERT_DIR"
        ) {
            cmd.env(&key, value);
        }
    }
    cmd.arg("pull");
    if spec.repo.starts_with("oci://") {
        cmd.arg(format!("{}/{}", spec.repo.trim_end_matches('/'), spec.name));
    } else {
        cmd.arg(&spec.name).args(["--repo", &spec.repo]);
    }
    cmd.args(["--version", &spec.version])
        .arg("--destination")
        .arg(&dest)
        .current_dir(tmp.path());
    tracing::info!(chart = %chart, "pulling Helm chart");
    let result = cmd.output().map_err(|e| HelmError::Pull {
        chart: chart.clone(),
        stderr: e.to_string(),
    })?;
    if !result.status.success() {
        return Err(HelmError::Pull {
            chart,
            stderr: String::from_utf8_lossy(&result.stderr).trim().to_string(),
        });
    }
    let pulled = std::fs::read_dir(&dest)
        .ok()
        .and_then(|entries| entries.flatten().map(|e| e.path()).find(|p| p.is_file()))
        .ok_or_else(|| HelmError::Pull {
            chart: chart.clone(),
            stderr: "helm pull wrote no file".to_string(),
        })?;
    let bytes = std::fs::read(&pulled).map_err(|source| HelmError::Io {
        path: pulled.clone(),
        source,
    })?;

    let (found_hex, sri_algo, digest) = match algo {
        "sha512" => {
            let d = sha2::Sha512::digest(&bytes).to_vec();
            (hex(&d), "sha512", d)
        }
        _ => {
            let d = sha2::Sha256::digest(&bytes).to_vec();
            (hex(&d), "sha256", d)
        }
    };
    if found_hex != hash_hex {
        let expected = hex_to_bytes(hash_hex)
            .map(|b| sri(sri_algo, &b))
            .unwrap_or_else(|| hash_hex.to_string());
        return Err(HelmError::HashMismatch {
            chart,
            expected,
            found: sri(sri_algo, &digest),
        });
    }

    // `--add-fixed` names the store path after the file.
    let name = store_name(out);
    let named = tmp.path().join(name);
    std::fs::rename(&pulled, &named).map_err(|source| HelmError::Io {
        path: named.clone(),
        source,
    })?;
    let added = output(
        command(Tool::NixStore)?
            .args(["--add-fixed", sri_algo])
            .arg(&named),
    )?;
    let added = String::from_utf8_lossy(&added).trim().to_string();
    if Path::new(&added) != out {
        return Err(HelmError::Spec {
            drv: out.to_path_buf(),
            message: format!(
                "nix-store added the chart at {added}, not at {}",
                out.display()
            ),
        });
    }
    Ok(())
}

/// Write `contents` as the store path `out`, the output of `deriver`, and
/// register it as valid with its NAR hash.
fn register(out: &Path, deriver: &Path, contents: &[u8]) -> Result<(), HelmError> {
    use std::os::unix::fs::PermissionsExt as _;

    let disk = real_path(out);
    let io = |path: &Path| {
        let path = path.to_path_buf();
        move |source| HelmError::Io { path, source }
    };
    // A file left by a run that stopped before registering it.
    if std::fs::symlink_metadata(&disk).is_ok() {
        std::fs::remove_file(&disk).map_err(io(&disk))?;
    }
    let tmp = disk.with_file_name(format!(".{}.kix-{}", store_name(out), std::process::id()));
    std::fs::write(&tmp, contents).map_err(io(&tmp))?;
    let file = std::fs::File::open(&tmp).map_err(io(&tmp))?;
    // The metadata Nix gives every store file.
    file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1))
        .map_err(io(&tmp))?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o444)).map_err(io(&tmp))?;
    std::fs::rename(&tmp, &disk).map_err(io(&disk))?;

    let nar = nar_of_file(contents);
    let registration = format!(
        "{}\nsha256:{}\n{}\n{}\n0\n",
        out.display(),
        hex(&sha2::Sha256::digest(&nar)),
        nar.len(),
        deriver.display()
    );
    let mut cmd = command(Tool::NixStore)?;
    cmd.arg("--load-db")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| NixCommandError {
        command: "nix-store --load-db".into(),
        dir: None,
        status: None,
        stderr: e.to_string(),
    })?;
    child
        .stdin
        .take()
        .expect("stdin is piped")
        .write_all(registration.as_bytes())
        .map_err(io(out))?;
    let result = child.wait_with_output().map_err(io(out))?;
    if !result.status.success() {
        return Err(NixCommandError {
            command: "nix-store --load-db".into(),
            dir: None,
            status: Some(result.status),
            stderr: String::from_utf8_lossy(&result.stderr).into_owned(),
        }
        .into());
    }
    tracing::info!(path = %out.display(), "registered Helm output");
    Ok(())
}

/// Hold a lock on `out` so that two Kix processes do not write it at once.
/// The lock is released when the returned file is dropped.
fn lock(out: &Path) -> Result<std::fs::File, HelmError> {
    let path = super::store::store_root()
        .join("nix/var/kix/locks")
        .join(out.file_name().unwrap_or_default());
    let io = |source| HelmError::Io {
        path: path.clone(),
        source,
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(io)?;
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(io)?;
    file.lock().map_err(io)?;
    Ok(file)
}

fn tempdir() -> Result<tempfile::TempDir, HelmError> {
    tempfile::Builder::new()
        .prefix("kix-helm-")
        .tempdir()
        .map_err(|source| HelmError::Io {
            path: std::env::temp_dir(),
            source,
        })
}

/// Return the name part of a store path, after its hash.
fn store_name(path: &Path) -> String {
    let base = path.file_name().unwrap_or_default().to_string_lossy();
    base.split_once('-')
        .map_or(base.to_string(), |(_, name)| name.to_string())
}

/// Return the NAR serialisation of a single regular, non-executable file.
fn nar_of_file(contents: &[u8]) -> Vec<u8> {
    fn put(out: &mut Vec<u8>, bytes: &[u8]) {
        out.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
        out.extend_from_slice(bytes);
        out.resize(out.len() + (8 - bytes.len() % 8) % 8, 0);
    }
    let mut nar = Vec::with_capacity(contents.len() + 128);
    for token in [
        &b"nix-archive-1"[..],
        b"(",
        b"type",
        b"regular",
        b"contents",
    ] {
        put(&mut nar, token);
    }
    put(&mut nar, contents);
    put(&mut nar, b")");
    nar
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_to_bytes(text: &str) -> Option<Vec<u8>> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

fn sri(algo: &str, digest: &[u8]) -> String {
    format!(
        "{algo}-{}",
        base64::engine::general_purpose::STANDARD.encode(digest)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_linux_error_names_its_derivations() {
        let stderr = "error: Cannot build '/nix/store/8ra65ddc4yn0clazfx013bblflvrahp5-chart.tgz.drv'.\n\
            Reason: required system or feature not available\n\
            error: Cannot build '/nix/store/ix2wlpn7zd422fv6srm7g1kkia6g65ma-helm-render-x.json.drv'.\n\
            Output paths:\n  /nix/store/zpabqz317wmlqihflawkmbklavail6i3-helm-render-x.json\n\
            again '/nix/store/8ra65ddc4yn0clazfx013bblflvrahp5-chart.tgz.drv'";
        assert_eq!(
            store_paths(stderr),
            [
                PathBuf::from("/nix/store/8ra65ddc4yn0clazfx013bblflvrahp5-chart.tgz.drv"),
                PathBuf::from("/nix/store/ix2wlpn7zd422fv6srm7g1kkia6g65ma-helm-render-x.json.drv"),
                PathBuf::from("/nix/store/zpabqz317wmlqihflawkmbklavail6i3-helm-render-x.json"),
            ]
        );
    }

    #[test]
    fn a_macos_trace_names_outputs_under_the_real_store_location() {
        let stderr = "error:\n\
            \x20      … while calling the 'readFile' builtin\n\
            \x20        at /Users/a/Library/Caches/kix/store/nix/store/1xxrs2mxddy5g2xjm4ivqwwi8wfsfb9w-source/kix/lib/helm.nix:26:30:\n\
            \x20      … while realising the context of path '/Users/a/Library/Caches/kix/store/nix/store/cicmixrzynsw1hcvsfv9gibpc6wqpmz5-helm-render-test-app.json'\n\
            \x20      error: building using a diverted store is not supported on this platform";
        assert_eq!(
            store_paths(stderr),
            [
                PathBuf::from("/nix/store/1xxrs2mxddy5g2xjm4ivqwwi8wfsfb9w-source"),
                PathBuf::from(
                    "/nix/store/cicmixrzynsw1hcvsfv9gibpc6wqpmz5-helm-render-test-app.json"
                ),
            ]
        );
    }

    #[test]
    fn text_that_only_looks_like_a_store_path_is_skipped() {
        let stderr = "see /nix/store/ for details\n\
            short /nix/store/abc-name\n\
            bad hash /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-name\n\
            no name /nix/store/zpabqz317wmlqihflawkmbklavail6i3\n\
            ok «/nix/store/zpabqz317wmlqihflawkmbklavail6i3-x»:1:2";
        assert_eq!(
            store_paths(stderr),
            [PathBuf::from(
                "/nix/store/zpabqz317wmlqihflawkmbklavail6i3-x"
            )]
        );
    }

    /// `nix-store --dump` of a file holding "hello" is 120 bytes with this
    /// hash.
    #[test]
    fn a_file_serialises_as_nix_does() {
        let nar = nar_of_file(b"hello");
        assert_eq!(nar.len(), 120);
        assert_eq!(
            hex(&sha2::Sha256::digest(&nar)),
            "0a430879c266f8b57f4092a0f935cf3facd48bbccde5760d4748ca405171e969"
        );
    }

    #[test]
    fn hashes_print_as_sri() {
        let digest = sha2::Sha256::digest(b"");
        assert_eq!(
            sri("sha256", &digest),
            "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        );
        assert_eq!(hex_to_bytes(&hex(&digest)).unwrap(), digest.to_vec());
    }

    #[test]
    fn a_missing_version_names_what_the_binary_ships() {
        let err = HelmError::VersionNotShipped {
            wanted: "4.3.1".into(),
            shipped: vec!["4.3.2".into()],
        };
        assert_eq!(
            err.to_string(),
            "This cluster's Kix library renders Helm charts with Helm 4.3.1, but this kix binary ships Helm 4.3.2. Update the kix input in flake.lock, or use the kix binary of the same version as the library"
        );
    }
}
