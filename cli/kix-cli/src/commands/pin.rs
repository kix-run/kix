//! `kix pin` — the promotion verb.
//!
//! The problem it solves is narrow and keeps recurring. Something outside the
//! compilation unit decides an image tag: a CI build finishes, or a person
//! decides that this build is the one that goes to production. The cluster
//! definition has no channel for that decision, so the decision gets made by
//! editing the definition in a working tree at deploy time and never
//! committing it. What is committed then renders a reference that does not
//! exist, and the first signal is ImagePullBackOff in production.
//!
//! `kix pin set` makes the decision a commit. It asks the registry what the
//! tag resolves to, refuses a tag that is not there, and writes the digest
//! into a pin file. `kix pin check` asks the registry whether every recorded
//! digest is still present, which is the check worth having on a pull
//! request, because a digest cannot be moved and a tag can.
//!
//! Both work from a file path with no cluster evaluation and no flake, on
//! purpose: the moment you most need to fix a pin is the moment evaluation is
//! unhappy about it.
//!
//! Design and reasoning: `v2_discussions/138_values_that_vary_per_deploy.md`.

use miette::{IntoDiagnostic, Result, miette};

use kix::pins::{Pin, PinFile};
use kix::registry::{Reference, RegistryClient, RegistryError, is_sha256_digest};

use crate::cli::{GlobalArgs, OutputFormat, PinCheckArgs, PinCommand, PinListArgs, PinSetArgs};
use crate::output;

mod locate;

pub fn run(command: &PinCommand, global: &GlobalArgs) -> Result<()> {
    match command {
        PinCommand::Set(args) => set(args, global),
        PinCommand::Check(args) => check(args, global),
        PinCommand::List(args) => list(args, global),
    }
}

// ----------------------------------------------------------------- kix pin set

fn set(args: &PinSetArgs, global: &GlobalArgs) -> Result<()> {
    // `--init` is the one path allowed to invent a file that is not there
    // yet; everything else has to find one, so that a typo cannot quietly
    // create a second pin file nothing reads.
    let located = if args.init {
        locate::locate_or_init(args.pins_file.as_deref(), &global.flake)?
    } else {
        locate::locate(args.pins_file.as_deref(), &global.flake)?
    };
    let pins_file = located.path.as_path();
    if !global.quiet
        && global.output != Some(OutputFormat::Json)
        && let Some(note) = located.note()
    {
        println!("{}", output::dim(&note));
    }

    let mut file = if args.init {
        PinFile::read_or_empty(pins_file).into_diagnostic()?
    } else {
        PinFile::read(pins_file).into_diagnostic()?
    };

    let existing = file.pins.get(&args.key).cloned();
    if existing.is_none() && !args.init {
        // The remedy has to be runnable from here. A refusal whose fix needs
        // a file the reader does not have is not a remedy.
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
                "a new pin needs a repository: kix pin set {} --repository <registry/repository> --tag <tag> --pins-file {} --init",
                args.key,
                pins_file.display()
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
                "--digest must be sha256 followed by 64 hex characters, and got '{d}'"
            ));
        }
        Some(d.clone())
    } else if args.no_resolve {
        None
    } else {
        if !global.quiet {
            println!("Resolving {reference}...");
        }
        Some(resolve(&reference)?)
    };

    if digest.is_none() && !global.quiet {
        eprintln!(
            "{}",
            output::yellow(
                "warning: writing a pin with no digest. Nothing checks that this tag exists, now or at deploy time."
            )
        );
    }

    let source_rev = args
        .source_rev
        .clone()
        .or_else(|| existing.as_ref().and_then(|p| p.source_rev.clone()));

    // Did anything that decides what runs actually move? `promotedBy` and
    // `resolvedAt` are bookkeeping, and stamping them on a promotion that
    // changed nothing would rewrite the file every time. That matters more
    // than tidiness: a CI job re-promoting an unchanged image would produce a
    // commit on every run, and the whole value of a pin file is that a commit
    // in it means something moved.
    let changed = moved(
        existing.as_ref(),
        &repository,
        &tag,
        digest.as_deref(),
        source_rev.as_deref(),
    );

    // The note is the one field a person wrote, so a promotion carries it
    // forward rather than replacing it. `--note` is how you change it, and
    // `--note ""` is how you clear it.
    let note = match &args.note {
        Some(n) if n.is_empty() => None,
        Some(n) => Some(n.clone()),
        None => existing.as_ref().and_then(|p| p.note.clone()),
    };

    let pin = if changed || note != existing.as_ref().and_then(|p| p.note.clone()) {
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
        file.pins.insert(args.key.clone(), pin.clone());
        file.write(args.force).into_diagnostic()?;
    }

    if global.output == Some(OutputFormat::Json) {
        let doc = serde_json::json!({
            "pinsFile": pins_file.display().to_string(),
            "key": args.key,
            "pin": pin,
            "changed": changed,
        });
        println!("{}", serde_json::to_string_pretty(&doc).into_diagnostic()?);
        return Ok(());
    }

    if !global.quiet {
        let verb = match (&existing, changed) {
            (None, _) => "added",
            (Some(_), true) => "updated",
            (Some(_), false) => "kept",
        };
        println!(
            "{} {} in {}",
            output::green(verb),
            args.key,
            pins_file.display()
        );
        println!("  {}:{}", pin.repository, pin.tag);
        match &pin.digest {
            Some(d) => println!("  {d}"),
            None => println!("  {}", output::yellow("no digest")),
        }
        if let Some(prev) = &existing
            && prev.digest != pin.digest
            && let Some(prev_digest) = &prev.digest
        {
            println!("  was {prev_digest}");
        }
        if !changed {
            println!(
                "  {}",
                output::dim("unchanged, so the file was not rewritten")
            );
        }
    }
    Ok(())
}

// --------------------------------------------------------------- kix pin check

/// One pin's verdict. `Ok` and `Warn` pass; `Fail` does not.
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

fn check(args: &PinCheckArgs, global: &GlobalArgs) -> Result<()> {
    let located = locate::locate(args.pins_file.as_deref(), &global.flake)?;
    let pins_file = located.path.as_path();
    let file = PinFile::read(pins_file).into_diagnostic()?;

    let selected: Vec<(&String, &Pin)> = file
        .pins
        .iter()
        .filter(|(k, _)| args.keys.is_empty() || args.keys.contains(k))
        .collect();

    if !args.keys.is_empty() {
        for wanted in &args.keys {
            if !file.pins.contains_key(wanted) {
                return Err(miette!(
                    "{} has no pin named '{}'. Pins in that file: {}.",
                    pins_file.display(),
                    wanted,
                    file.pins.keys().cloned().collect::<Vec<_>>().join(", ")
                ));
            }
        }
    }

    let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;
    let client = if args.offline {
        None
    } else {
        Some(RegistryClient::new().into_diagnostic()?)
    };

    let mut results: Vec<(String, Verdict)> = Vec::new();

    for (key, pin) in &selected {
        results.push((
            (*key).clone(),
            judge(key, pin, args, client.as_ref(), &runtime),
        ));
    }

    // The freshness assertion, reported separately because it is a different
    // question. Everything above asks whether the recorded reference is real.
    // This asks whether it is current. A promotion step that silently did not
    // run leaves every pin real, every check green, and the cluster running
    // old code, which is the one failure the rest of the design cannot see.
    let mut stale: Vec<Stale> = Vec::new();
    if let Some(want) = &args.source_rev {
        for (key, pin) in &selected {
            let Some(have) = &pin.source_rev else {
                continue;
            };
            if !revs_match(have, want) {
                stale.push(Stale {
                    key: (*key).clone(),
                    built_from: have.clone(),
                    expected: want.clone(),
                });
            }
        }
    }

    let failed = results.iter().any(|(_, v)| v.failed()) || !stale.is_empty();

    if global.output == Some(OutputFormat::Json) {
        let doc = serde_json::json!({
            "pinsFile": pins_file.display().to_string(),
            "pins": results.iter().map(|(k, v)| serde_json::json!({
                "key": k,
                "result": v.label(),
                "message": v.message(),
            })).collect::<Vec<_>>(),
            "stale": stale,
            "ok": !failed,
        });
        println!("{}", serde_json::to_string_pretty(&doc).into_diagnostic()?);
    } else {
        print_check_text(
            &located
                .note()
                .unwrap_or_else(|| pins_file.display().to_string()),
            &results,
            &stale,
            global,
        );
    }

    if failed {
        std::process::exit(1);
    }
    Ok(())
}

fn judge(
    key: &str,
    pin: &Pin,
    args: &PinCheckArgs,
    client: Option<&RegistryClient>,
    runtime: &tokio::runtime::Runtime,
) -> Verdict {
    let Some(digest_ref) = pin.digest_reference() else {
        let msg = format!(
            "{} has no digest, so nothing verifies that this tag exists",
            pin.reference()
        );
        return if args.allow_unresolved {
            Verdict::Warn(msg)
        } else {
            Verdict::Fail(format!(
                "{msg}. Resolve it with `kix pin set {key} --tag <tag>`, or pass --allow-unresolved."
            ))
        };
    };

    let Some(client) = client else {
        return Verdict::Ok(format!("{} (shape only, offline)", pin.reference()));
    };

    // By digest, not by tag. A tag that has moved is a fact worth reporting;
    // a digest that has gone is the thing that breaks a deploy.
    let by_digest = Reference::parse(&digest_ref).map_err(RegistryError::from);
    let digest_result = match by_digest {
        Ok(r) => runtime.block_on(client.resolve(&r)),
        Err(e) => Err(e),
    };
    if let Err(e) = digest_result {
        return Verdict::Fail(format!("{digest_ref} is not in the registry: {e}"));
    }

    // The tag is secondary. A retention job that deletes an old tag whose
    // digest still runs must not turn a pull request red, because there is
    // nothing the author can do about it and nothing is broken.
    match Reference::from_parts(&pin.repository, &pin.tag) {
        Ok(by_tag) => match runtime.block_on(client.resolve(&by_tag)) {
            Ok(resolved) if Some(&resolved.digest) == pin.digest.as_ref() => {
                Verdict::Ok(format!("{} resolves to the pinned digest", pin.reference()))
            }
            Ok(resolved) => Verdict::Warn(format!(
                "the digest is present, but tag {} now points at {}. The pinned digest is what runs.",
                pin.tag, resolved.digest
            )),
            Err(_) => Verdict::Warn(format!(
                "the digest is present, but tag {} is gone from the registry. The pinned digest is what runs.",
                pin.tag
            )),
        },
        Err(e) => Verdict::Fail(format!("{} is not a valid reference: {e}", pin.reference())),
    }
}

/// A pin that records a source revision other than the one being checked for.
#[derive(Debug, Clone, serde::Serialize)]
struct Stale {
    key: String,
    #[serde(rename = "builtFrom")]
    built_from: String,
    expected: String,
}

fn print_check_text(
    path: &str,
    results: &[(String, Verdict)],
    stale: &[Stale],
    global: &GlobalArgs,
) {
    if !global.quiet {
        println!("{path}");
        println!();
    }
    for (key, verdict) in results {
        let mark = match verdict {
            Verdict::Ok(_) => output::green("ok  "),
            Verdict::Warn(_) => output::yellow("warn"),
            Verdict::Fail(_) => output::red("fail"),
        };
        println!("  {mark}  {key}  {}", verdict.message());
    }

    if !stale.is_empty() {
        println!();
        println!("  Not current:");
        for s in stale {
            println!(
                "  {}  {} was built from {}, and this check expects {}.",
                output::red("fail"),
                s.key,
                s.built_from,
                s.expected
            );
        }
        println!();
        println!("  The promotion step did not run for this revision, so the cluster would deploy");
        println!("  older images than the source it is built from.");
    }

    let failed = results.iter().filter(|(_, v)| v.failed()).count();
    let warned = results
        .iter()
        .filter(|(_, v)| matches!(v, Verdict::Warn(_)))
        .count();
    if !global.quiet {
        println!();
        println!(
            "{} pins checked, {failed} failed, {warned} warned",
            results.len()
        );
        if !stale.is_empty() {
            println!("{} not current", stale.len());
        }
    }
}

// ---------------------------------------------------------------- kix pin list

fn list(args: &PinListArgs, global: &GlobalArgs) -> Result<()> {
    let located = locate::locate(args.pins_file.as_deref(), &global.flake)?;
    let pins_file = located.path.as_path();
    let file = PinFile::read(pins_file).into_diagnostic()?;
    if !global.quiet
        && global.output != Some(OutputFormat::Json)
        && let Some(note) = located.note()
    {
        println!("{}", output::dim(&note));
    }

    if global.output == Some(OutputFormat::Json) {
        println!(
            "{}",
            serde_json::to_string_pretty(&file.pins).into_diagnostic()?
        );
        return Ok(());
    }

    if file.pins.is_empty() {
        println!("{} holds no pins", pins_file.display());
        return Ok(());
    }

    for (key, pin) in &file.pins {
        println!("{}", output::bold(key));
        println!("  {}:{}", pin.repository, pin.tag);
        match &pin.digest {
            Some(d) => println!("  {d}"),
            None => println!("  {}", output::yellow("no digest")),
        }
        if let Some(rev) = &pin.source_rev {
            println!("  built from {rev}");
        }
        if let Some(by) = &pin.promoted_by {
            let when = pin.resolved_at.as_deref().unwrap_or("at an unknown time");
            println!("  {}", output::dim(&format!("promoted by {by}, {when}")));
        }
        if let Some(note) = &pin.note {
            println!("  {note}");
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------- shared

fn resolve(reference: &Reference) -> Result<String> {
    let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;
    let client = RegistryClient::new().into_diagnostic()?;
    let resolved = runtime
        .block_on(client.resolve(reference))
        .map_err(|e| miette!("{e}"))?;
    Ok(resolved.digest)
}

/// Whether a promotion actually changes what runs. `promotedBy` and
/// `resolvedAt` are deliberately not part of this: they describe the
/// promotion, not the thing promoted.
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

/// Two revisions match when one is a prefix of the other, so a short sha in a
/// pin file and a full sha from CI are the same revision.
fn revs_match(a: &str, b: &str) -> bool {
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    !short.is_empty() && long.starts_with(short)
}

/// Who to record as having promoted this. CI names its run, because that is
/// what someone reading the file six months later needs in order to find the
/// build. A person gets user@host.
fn default_promoted_by() -> String {
    if let (Ok(workflow), Ok(run)) = (
        std::env::var("GITHUB_WORKFLOW"),
        std::env::var("GITHUB_RUN_ID"),
    ) && !run.is_empty()
    {
        return format!("ci:{workflow}#{run}");
    }
    // Every other CI system publishes a URL for the running job, which is
    // more useful than a name and a number anyway. GitLab, then Jenkins and
    // the several tools that copied its variable, then Buildkite.
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
        // A moved tag, a re-resolved digest, a new repository and a new
        // source revision are all real changes.
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
}
