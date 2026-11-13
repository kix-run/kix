//! Promote and verify container image pins in a pin file.
//!
//! `kix pin set` resolves an image tag against the registry, rejects tags that
//! do not exist, and writes the resolved digest into a pin file. `kix pin rm`
//! removes an entry from a pin file. `kix pin check` verifies that every
//! recorded digest is still present in the registry and, when `--source-rev` is
//! given, that pinned images match the expected source revision.
//!
//! Each subcommand operates directly on the pin file without evaluating the
//! flake, so broken or missing pins can be repaired even when Nix evaluation
//! fails.

use std::collections::BTreeMap;
use std::fmt::Write;

use miette::{IntoDiagnostic, Result, miette};

use kix::pins::{Pin, PinFile, PinKey};
use kix::registry::{Reference, RegistryClient, RegistryError, is_sha256_digest};

use crate::cli::{
    GlobalArgs, OutputFormat, PinCheckArgs, PinCommand, PinListArgs, PinRmArgs, PinSetArgs,
};
use crate::exit::Exit;
use crate::output::{self, CommandResponse};

use super::CommandContext;

mod locate;

pub fn run(command: &PinCommand, ctx: &CommandContext) -> Result<Exit> {
    match command {
        PinCommand::Set(args) => set(args, ctx).map(Exit::from),
        PinCommand::Rm(args) => rm(args, &ctx.global).map(Exit::from),
        PinCommand::Check(args) => check(args, ctx),
        PinCommand::List(args) => list(args, &ctx.global).map(Exit::from),
    }
}

fn set(args: &PinSetArgs, ctx: &CommandContext) -> Result<()> {
    let global = &ctx.global;
    // Only `--init` may create a new pin file. Without it, a mistyped path or
    // working directory must fail rather than create a second pin file that no
    // cluster reads.
    let located = if args.init {
        locate::locate_or_init(args.pins_file.as_deref(), &global.flake)?
    } else {
        locate::locate(args.pins_file.as_deref(), &global.flake)?
    };
    let pins_file = located.path.as_path();
    if output::format() == OutputFormat::Text
        && let Some(note) = located.note()
    {
        crate::say!("{}", output::dim(&note));
    }

    let mut file = if args.init {
        PinFile::read_or_empty(pins_file).into_diagnostic()?
    } else {
        PinFile::read(pins_file).into_diagnostic()?
    };

    let key = PinKey::parse(&args.key, args.option.as_deref()).map_err(|e| miette!("{e}"))?;
    let existing = file.get(&key).cloned();
    // Adding a new instance pin does not require `--init` because cluster
    // evaluation rejects pins for unknown instances. Adding a new entry under
    // `images` requires `--init` so a typo in the key name is caught instead
    // of writing an unused entry.
    if existing.is_none() && !args.init && matches!(key, PinKey::Image(_)) {
        return Err(miette!(
            "{} has no pin named '{}'. Pins in that file: {}.\n\nAdd it with:\n  kix pin set {} --repository <registry/repository> --tag <tag> --pins-file {} --init",
            pins_file.display(),
            args.key,
            if file.pins.is_empty() {
                "none".to_string()
            } else {
                file.pins.keys().cloned().collect::<Vec<_>>().join(", ")
            },
            args.key,
            pins_file.display(),
        ));
    }

    let repository = args
        .repository
        .clone()
        .or_else(|| existing.as_ref().map(|p| p.repository.clone()))
        .ok_or_else(|| {
            miette!(
                "a new pin needs a repository: kix pin set {} --repository <registry/repository> --tag <tag> --pins-file {}{}",
                key.arguments(),
                pins_file.display(),
                if matches!(key, PinKey::Image(_)) { " --init" } else { "" }
            )
        })?;

    let tag = args
        .tag
        .clone()
        .or_else(|| existing.as_ref().map(|p| p.tag.clone()))
        .ok_or_else(|| miette!("a new pin needs a tag: pass --tag <tag>"))?;

    let reference = Reference::from_parts(&repository, &tag).into_diagnostic()?;

    let digest = if let Some(d) = &args.digest {
        if !is_sha256_digest(d) {
            return Err(miette!(
                "invalid digest '{d}'. Use sha256: followed by 64 hexadecimal characters"
            ));
        }
        Some(d.clone())
    } else if args.no_resolve {
        None
    } else {
        crate::say!("Resolving {reference}...");
        Some(resolve(&reference, ctx.runtime()?)?)
    };

    if digest.is_none() {
        crate::esay!(
            "{}",
            output::yellow(
                "warning: saving this pin without a digest. Kix has not checked whether the tag exists and will not check it during deployment."
            )
        );
    }

    let source_rev = args
        .source_rev
        .clone()
        .or_else(|| existing.as_ref().and_then(|p| p.source_rev.clone()));

    // Skip updating `promotedBy` and `resolvedAt` when the image reference and
    // source revision are unchanged, so re-running a CI promotion job on an
    // unchanged image does not dirty the working tree.
    let changed = moved(
        existing.as_ref(),
        &repository,
        &tag,
        digest.as_deref(),
        source_rev.as_deref(),
    );

    // Notes describe a specific pinned image. Drop an existing note when the
    // image changes unless `--note` supplies a new one; `--note ""` clears it.
    let kept_note = existing.as_ref().and_then(|p| p.note.clone());
    let dropped_note = kept_note.clone().filter(|_| changed && args.note.is_none());
    let note = match &args.note {
        Some(n) if n.is_empty() => None,
        Some(n) => Some(n.clone()),
        None if changed => None,
        None => kept_note.clone(),
    };

    let pin = if changed || note != kept_note {
        Pin {
            repository,
            tag,
            digest,
            source_rev,
            promoted_by: Some(args.promoted_by.clone().unwrap_or_else(default_promoted_by)),
            resolved_at: Some(now_rfc3339()),
            note,
        }
    } else {
        existing.clone().expect("unchanged implies an existing pin")
    };

    let changed = changed || existing.as_ref() != Some(&pin);
    if changed {
        file.insert(key.clone(), pin.clone());
        file.write(args.force).into_diagnostic()?;
    }

    output::result(&PinSetResponse {
        pins_file: pins_file.display().to_string(),
        key: args.key.clone(),
        option: option_of(&key).map(str::to_string),
        pin,
        changed,
        dropped_note,
        previous: existing,
        shown_key: key.to_string(),
    })
}

/// What `kix pin set` wrote.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PinSetResponse {
    /// The pin file, as a path.
    pins_file: String,
    /// The image pin name or instance name, as given.
    key: String,
    /// The option path of an instance pin, or null for an image pin.
    option: Option<String>,
    /// The pin as the file now holds it.
    pin: Pin,
    /// Whether the file was rewritten.
    changed: bool,
    /// The note Kix dropped because it described the old image.
    dropped_note: Option<String>,
    #[serde(skip)]
    #[schemars(skip)]
    previous: Option<Pin>,
    #[serde(skip)]
    #[schemars(skip)]
    shown_key: String,
}

impl CommandResponse for PinSetResponse {
    fn text(&self) -> String {
        let mut out = String::new();
        let verb = match (&self.previous, self.changed) {
            (None, _) => "added",
            (Some(_), true) => "updated",
            (Some(_), false) => "kept",
        };
        let _ = writeln!(
            out,
            "{} {} in {}",
            output::green(verb),
            self.shown_key,
            self.pins_file
        );
        let _ = writeln!(out, "  {}:{}", self.pin.repository, self.pin.tag);
        match &self.pin.digest {
            Some(d) => _ = writeln!(out, "  {d}"),
            None => _ = writeln!(out, "  {}", output::yellow("no digest")),
        }
        if let Some(prev) = &self.previous
            && prev.digest != self.pin.digest
            && let Some(prev_digest) = &prev.digest
        {
            let _ = writeln!(out, "  was {prev_digest}");
        }
        if let Some(dropped) = &self.dropped_note {
            let _ = writeln!(
                out,
                "  {}",
                output::yellow(&format!(
                    "dropped the note, which described the old image: {dropped}"
                ))
            );
        }
        if !self.changed {
            let _ = writeln!(
                out,
                "  {}",
                output::dim("unchanged, so the file was not rewritten")
            );
        }
        out
    }

    fn text_is_progress(&self) -> bool {
        true
    }
}

fn rm(args: &PinRmArgs, global: &GlobalArgs) -> Result<()> {
    let located = locate::locate(args.pins_file.as_deref(), &global.flake)?;
    let pins_file = located.path.as_path();
    if output::format() == OutputFormat::Text
        && let Some(note) = located.note()
    {
        crate::say!("{}", output::dim(&note));
    }

    let mut file = PinFile::read(pins_file).into_diagnostic()?;
    let key = PinKey::parse(&args.key, args.option.as_deref()).map_err(|e| miette!("{e}"))?;
    let Some(removed) = file.remove(&key) else {
        let present = if file.is_empty() {
            "none".to_string()
        } else {
            file.entries()
                .map(|(k, _)| k.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        };
        return Err(miette!(
            "{} has no pin named '{key}'. Pins in that file: {present}.",
            pins_file.display(),
        ));
    };

    file.write(args.force).into_diagnostic()?;

    output::result(&PinRmResponse {
        pins_file: pins_file.display().to_string(),
        key: args.key.clone(),
        option: option_of(&key).map(str::to_string),
        pin: removed,
        shown_key: key.to_string(),
    })
}

/// What `kix pin rm` removed.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PinRmResponse {
    /// The pin file, as a path.
    pins_file: String,
    /// The image pin name or instance name, as given.
    key: String,
    /// The option path of an instance pin, or null for an image pin.
    option: Option<String>,
    /// The pin the file held.
    pin: Pin,
    #[serde(skip)]
    #[schemars(skip)]
    shown_key: String,
}

impl CommandResponse for PinRmResponse {
    fn text(&self) -> String {
        let mut out = format!(
            "{} {} from {}\n  was {}:{}\n",
            output::green("removed"),
            self.shown_key,
            self.pins_file,
            self.pin.repository,
            self.pin.tag
        );
        if let Some(d) = &self.pin.digest {
            let _ = writeln!(out, "  {d}");
        }
        out
    }

    fn text_is_progress(&self) -> bool {
        true
    }
}

/// Verification outcome for a single pin. `Ok` and `Warn` pass; `Fail` does not.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Verdict {
    Ok(String),
    Warn(String),
    Fail(String),
}

impl Verdict {
    fn failed(&self) -> bool {
        matches!(self, Verdict::Fail(_))
    }
    fn message(&self) -> &str {
        match self {
            Verdict::Ok(m) | Verdict::Warn(m) | Verdict::Fail(m) => m,
        }
    }
    fn label(&self) -> &'static str {
        match self {
            Verdict::Ok(_) => "ok",
            Verdict::Warn(_) => "warning",
            Verdict::Fail(_) => "failed",
        }
    }
}

fn check(args: &PinCheckArgs, ctx: &CommandContext) -> Result<Exit> {
    let global = &ctx.global;
    let located = locate::locate(args.pins_file.as_deref(), &global.flake)?;
    let pins_file = located.path.as_path();
    let file = PinFile::read(pins_file).into_diagnostic()?;

    // A key names an `images` pin, or every pin of an instance.
    let selects = |key: &PinKey, wanted: &str| match key {
        PinKey::Image(name) => name == wanted,
        PinKey::Instance { instance, .. } => instance == wanted,
    };
    let selected: Vec<(PinKey, &Pin)> = file
        .entries()
        .filter(|(k, _)| args.keys.is_empty() || args.keys.iter().any(|w| selects(k, w)))
        .collect();

    for wanted in &args.keys {
        if !file.entries().any(|(k, _)| selects(&k, wanted)) {
            return Err(miette!(
                "{} has no pin named '{}'. Pins in that file: {}.",
                pins_file.display(),
                wanted,
                file.entries()
                    .map(|(k, _)| k.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }

    let runtime = ctx.runtime()?;
    let client = if args.offline {
        None
    } else {
        Some(RegistryClient::new().into_diagnostic()?)
    };

    let mut results: Vec<(PinKey, Verdict)> = Vec::new();

    for (key, pin) in &selected {
        results.push((key.clone(), judge(key, pin, args, client.as_ref(), runtime)));
    }

    // Check source-revision freshness separately from registry existence: a
    // pin whose promotion step never ran still resolves in the registry, but
    // its recorded `sourceRev` lags behind `--source-rev`.
    let mut stale: Vec<Stale> = Vec::new();
    if let Some(want) = &args.source_rev {
        for (key, pin) in &selected {
            let Some(have) = &pin.source_rev else {
                continue;
            };
            if !revs_match(have, want) {
                stale.push(Stale {
                    key: key.to_string(),
                    built_from: have.clone(),
                    expected: want.clone(),
                });
            }
        }
    }

    let failed = results.iter().any(|(_, v)| v.failed()) || !stale.is_empty();

    output::result(&PinCheckResponse {
        pins_file: pins_file.display().to_string(),
        pins: results
            .iter()
            .map(|(k, v)| CheckedPin {
                key: key_of(k).to_string(),
                option: option_of(k).map(str::to_string),
                result: v.label().to_string(),
                message: v.message().to_string(),
                shown_key: k.to_string(),
            })
            .collect(),
        stale,
        ok: !failed,
        heading: located
            .note()
            .unwrap_or_else(|| pins_file.display().to_string()),
    })?;

    Ok(Exit::failure_if(failed))
}

fn judge(
    key: &PinKey,
    pin: &Pin,
    args: &PinCheckArgs,
    client: Option<&RegistryClient>,
    runtime: &tokio::runtime::Runtime,
) -> Verdict {
    let Some(digest_ref) = pin.digest_reference() else {
        let msg = format!(
            "{} has no digest. Kix cannot verify the pinned image",
            pin.reference()
        );
        return if args.allow_unresolved {
            Verdict::Warn(msg)
        } else {
            Verdict::Fail(format!(
                "{msg}. Resolve it with `kix pin set {} --tag <tag>`, or pass --allow-unresolved.",
                key.arguments()
            ))
        };
    };

    let Some(client) = client else {
        return Verdict::Ok(format!(
            "{} (format checked offline; registry not checked)",
            pin.reference()
        ));
    };

    // Verify the digest first because deployments pull by digest; a missing
    // digest breaks a deploy, whereas a moved or deleted tag only merits a
    // warning as long as the pinned digest still exists.
    let by_digest = Reference::parse(&digest_ref).map_err(RegistryError::from);
    let digest_result = match by_digest {
        Ok(r) => runtime.block_on(client.resolve(&r)),
        Err(e) => Err(e),
    };
    if let Err(e) = digest_result {
        return Verdict::Fail(format!(
            "could not verify {digest_ref} in the registry: {e}"
        ));
    }

    match Reference::from_parts(&pin.repository, &pin.tag) {
        Ok(by_tag) => match runtime.block_on(client.resolve(&by_tag)) {
            Ok(resolved) if Some(&resolved.digest) == pin.digest.as_ref() => {
                Verdict::Ok(format!("{} resolves to the pinned digest", pin.reference()))
            }
            Ok(resolved) => Verdict::Warn(format!(
                "the digest is present, but tag {} now points at {}. Deployments continue to use the pinned digest.",
                pin.tag, resolved.digest
            )),
            Err(e) => Verdict::Warn(format!(
                "the digest is present, but Kix could not check tag {}: {e}. Deployments continue to use the pinned digest.",
                pin.tag
            )),
        },
        Err(e) => Verdict::Fail(format!("{} is not a valid reference: {e}", pin.reference())),
    }
}

/// A pin that records a source revision other than the one being checked for.
#[derive(Debug, Clone, serde::Serialize, schemars::JsonSchema)]
struct Stale {
    key: String,
    #[serde(rename = "builtFrom")]
    built_from: String,
    expected: String,
}

/// One pin that `kix pin check` checked.
#[derive(serde::Serialize, schemars::JsonSchema)]
struct CheckedPin {
    /// The image pin name or instance name.
    key: String,
    /// The option path of an instance pin, or null for an image pin.
    option: Option<String>,
    /// `ok`, `warning`, or `failed`.
    result: String,
    message: String,
    #[serde(skip)]
    #[schemars(skip)]
    shown_key: String,
}

/// What `kix pin check` found.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PinCheckResponse {
    /// The pin file, as a path.
    pins_file: String,
    pins: Vec<CheckedPin>,
    /// Pins built from a source revision other than `--source-rev`.
    stale: Vec<Stale>,
    /// Whether every pin passed and none is stale.
    ok: bool,
    #[serde(skip)]
    #[schemars(skip)]
    heading: String,
}

impl CommandResponse for PinCheckResponse {
    fn text(&self) -> String {
        // The heading and the counts are progress, which `-q` hides.
        let quiet = output::quiet();
        let mut out = String::new();
        if !quiet {
            let _ = writeln!(out, "{}\n", self.heading);
        }
        for p in &self.pins {
            let mark = match p.result.as_str() {
                "ok" => output::green("ok  "),
                "warning" => output::yellow("warn"),
                _ => output::red("fail"),
            };
            let _ = writeln!(out, "  {mark}  {}  {}", p.shown_key, p.message);
        }

        if !self.stale.is_empty() {
            let _ = writeln!(out, "\n  Not current:");
            for s in &self.stale {
                let _ = writeln!(
                    out,
                    "  {}  {} was built from {}, and this check expects {}.",
                    output::red("fail"),
                    s.key,
                    s.built_from,
                    s.expected
                );
            }
            out.push_str(
                "\n  The promotion step did not run for this revision, so the cluster would deploy\n  \
                 older images than the source it is built from.\n",
            );
        }

        if !quiet {
            let failed = self.pins.iter().filter(|p| p.result == "failed").count();
            let warned = self.pins.iter().filter(|p| p.result == "warning").count();
            let _ = writeln!(
                out,
                "\n{} pins checked, {failed} failed, {warned} warned",
                self.pins.len()
            );
            if !self.stale.is_empty() {
                let _ = writeln!(out, "{} not current", self.stale.len());
            }
        }
        out
    }
}

fn list(args: &PinListArgs, global: &GlobalArgs) -> Result<()> {
    let located = locate::locate(args.pins_file.as_deref(), &global.flake)?;
    let pins_file = located.path.as_path();
    let file = PinFile::read(pins_file).into_diagnostic()?;
    if output::format() == OutputFormat::Text
        && let Some(note) = located.note()
    {
        crate::say!("{}", output::dim(&note));
    }

    output::result(&PinListResponse {
        entries: file
            .entries()
            .map(|(k, p)| (k.to_string(), p.clone()))
            .collect(),
        images: file.pins,
        instances: file.instances,
        pins_file: pins_file.display().to_string(),
    })
}

/// The pins in a pin file, as the file holds them.
#[derive(serde::Serialize, schemars::JsonSchema)]
pub(crate) struct PinListResponse {
    /// Image pins, by pin name.
    images: BTreeMap<String, Pin>,
    /// Instance pins, by `<namespace>/<instance>`, then option path.
    instances: BTreeMap<String, BTreeMap<String, Pin>>,
    #[serde(skip)]
    #[schemars(skip)]
    entries: Vec<(String, Pin)>,
    #[serde(skip)]
    #[schemars(skip)]
    pins_file: String,
}

impl CommandResponse for PinListResponse {
    fn text(&self) -> String {
        if self.entries.is_empty() {
            return format!("{} holds no pins", self.pins_file);
        }
        let mut out = String::new();
        for (key, pin) in &self.entries {
            let _ = writeln!(out, "{}", output::bold(key));
            let _ = writeln!(out, "  {}:{}", pin.repository, pin.tag);
            match &pin.digest {
                Some(d) => _ = writeln!(out, "  {d}"),
                None => _ = writeln!(out, "  {}", output::yellow("no digest")),
            }
            if let Some(rev) = &pin.source_rev {
                let _ = writeln!(out, "  built from {rev}");
            }
            if let Some(by) = &pin.promoted_by {
                let when = pin.resolved_at.as_deref().unwrap_or("at an unknown time");
                let _ = writeln!(
                    out,
                    "  {}",
                    output::dim(&format!("promoted by {by}, {when}"))
                );
            }
            if let Some(note) = &pin.note {
                let _ = writeln!(out, "  {note}");
            }
        }
        out
    }
}

/// Return the image pin name or instance name for JSON output.
fn key_of(key: &PinKey) -> &str {
    match key {
        PinKey::Image(name) => name,
        PinKey::Instance { instance, .. } => instance,
    }
}

/// Return the option path for an instance pin, or `None` for an `images` pin.
fn option_of(key: &PinKey) -> Option<&str> {
    match key {
        PinKey::Image(_) => None,
        PinKey::Instance { option, .. } => Some(option),
    }
}

fn resolve(reference: &Reference, runtime: &tokio::runtime::Runtime) -> Result<String> {
    let client = RegistryClient::new().into_diagnostic()?;
    let resolved = runtime
        .block_on(client.resolve(reference))
        .map_err(|e| miette!("{e}"))?;
    Ok(resolved.digest)
}

/// Return `true` when the promoted image reference or source revision differs
/// from `existing`.
///
/// Excludes `promotedBy` and `resolvedAt` because they record provenance of the
/// promotion rather than the image being promoted.
fn moved(
    existing: Option<&Pin>,
    repository: &str,
    tag: &str,
    digest: Option<&str>,
    source_rev: Option<&str>,
) -> bool {
    match existing {
        None => true,
        Some(prev) => {
            prev.repository != repository
                || prev.tag != tag
                || prev.digest.as_deref() != digest
                || prev.source_rev.as_deref() != source_rev
        }
    }
}

/// Return `true` when one Git revision string is a non-empty prefix of the other,
/// so a short SHA in a pin file matches a full SHA from CI.
fn revs_match(a: &str, b: &str) -> bool {
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    !short.is_empty() && long.starts_with(short)
}

/// Determine the default `promotedBy` identifier from CI environment variables
/// or the local `user@host`.
fn default_promoted_by() -> String {
    if let (Ok(workflow), Ok(run)) = (
        std::env::var("GITHUB_WORKFLOW"),
        std::env::var("GITHUB_RUN_ID"),
    ) && !run.is_empty()
    {
        return format!("ci:{workflow}#{run}");
    }
    for var in ["CI_JOB_URL", "BUILD_URL", "BUILDKITE_BUILD_URL"] {
        if let Ok(url) = std::env::var(var)
            && !url.is_empty()
        {
            return format!("ci:{url}");
        }
    }
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "unknown".into());
    let host = hostname();
    format!("{user}@{host}")
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown-host".into())
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pin(tag: &str, digest: Option<&str>) -> Pin {
        Pin {
            repository: "reg.example/app".into(),
            tag: tag.into(),
            digest: digest.map(str::to_string),
            source_rev: None,
            promoted_by: Some("someone".into()),
            resolved_at: Some("2026-01-01T00:00:00Z".into()),
            note: None,
        }
    }

    #[test]
    fn re_promoting_the_same_reference_is_not_a_change() {
        let prev = pin("v1", Some("sha256:aa"));
        // Same everything: the file must not be rewritten, or a CI job that
        // re-promotes an unchanged image commits on every run.
        assert!(!moved(
            Some(&prev),
            "reg.example/app",
            "v1",
            Some("sha256:aa"),
            None
        ));
        // Moving the tag, digest, repository, or source revision is a change.
        assert!(moved(
            Some(&prev),
            "reg.example/app",
            "v2",
            Some("sha256:aa"),
            None
        ));
        assert!(moved(
            Some(&prev),
            "reg.example/app",
            "v1",
            Some("sha256:bb"),
            None
        ));
        assert!(moved(
            Some(&prev),
            "reg.example/other",
            "v1",
            Some("sha256:aa"),
            None
        ));
        assert!(moved(
            Some(&prev),
            "reg.example/app",
            "v1",
            Some("sha256:aa"),
            Some("deadbeef")
        ));
        // A pin that does not exist yet is always a change.
        assert!(moved(None, "reg.example/app", "v1", None, None));
    }

    #[test]
    fn a_short_revision_matches_the_full_one_it_prefixes() {
        assert!(revs_match("5d5dda2", "5d5dda2e5c1f"));
        assert!(revs_match("5d5dda2e5c1f", "5d5dda2"));
        assert!(!revs_match("5d5dda2", "aaaaaaa"));
        assert!(!revs_match("", "5d5dda2"));
    }

    #[test]
    fn ci_is_named_by_its_run_rather_than_by_a_runner_user() {
        // Safety: single-threaded test process; the variables are read once.
        unsafe {
            std::env::set_var("GITHUB_WORKFLOW", "deploy");
            std::env::set_var("GITHUB_RUN_ID", "3981");
        }
        assert_eq!(default_promoted_by(), "ci:deploy#3981");
        unsafe {
            std::env::remove_var("GITHUB_WORKFLOW");
            std::env::remove_var("GITHUB_RUN_ID");
        }
    }

    fn test_global() -> GlobalArgs {
        GlobalArgs {
            output: None,
            verbose: 0,
            quiet: true,
            no_color: true,
            context: None,
            flake: ".".into(),
            no_cache: false,
            override_input: Vec::new(),
        }
    }

    #[test]
    fn rm_removes_package_and_instance_pins_and_reverts_version_to_1() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        let mut file = PinFile::empty(&path);
        file.insert(PinKey::Image("nginx".into()), pin("1.27", None));
        file.insert(PinKey::Image("web".into()), pin("v1", None));
        file.insert(
            PinKey::parse("ns/app", None).unwrap(),
            pin("v2", Some(&format!("sha256:{}", "a".repeat(64)))),
        );
        file.write(false).unwrap();

        let on_disk: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on_disk["version"], 2);

        rm(
            &PinRmArgs {
                key: "nginx".into(),
                option: None,
                force: false,
                pins_file: Some(path.clone()),
            },
            &test_global(),
        )
        .unwrap();

        let after_pkg = PinFile::read(&path).unwrap();
        assert!(!after_pkg.pins.contains_key("nginx"));
        assert!(after_pkg.pins.contains_key("web"));
        assert!(after_pkg.instances.contains_key("ns/app"));

        rm(
            &PinRmArgs {
                key: "ns/app".into(),
                option: None,
                force: false,
                pins_file: Some(path.clone()),
            },
            &test_global(),
        )
        .unwrap();

        let after_inst = PinFile::read(&path).unwrap();
        assert!(after_inst.instances.is_empty());
        let on_disk: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on_disk["version"], 1);
        assert!(on_disk.get("instances").is_none());
    }

    #[test]
    fn rm_errors_when_target_is_not_pinned() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        let mut file = PinFile::empty(&path);
        file.insert(PinKey::Image("nginx".into()), pin("1.27", None));
        file.write(false).unwrap();

        let err = rm(
            &PinRmArgs {
                key: "missing".into(),
                option: None,
                force: false,
                pins_file: Some(path.clone()),
            },
            &test_global(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("has no pin named 'missing'"));

        let err = rm(
            &PinRmArgs {
                key: "ns/app".into(),
                option: None,
                force: false,
                pins_file: Some(path),
            },
            &test_global(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("has no pin named 'ns/app image'"));
    }
}
