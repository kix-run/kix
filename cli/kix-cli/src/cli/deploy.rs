//! Arguments of `kix deploy` and `kix rollback`.

use super::PlanArgs;
use clap::ValueEnum;

#[derive(clap::Args)]
pub struct DeployArgs {
    #[command(flatten)]
    pub plan: PlanArgs,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview only: run `kix plan` with the same flags and make no changes.
    /// When combined with `--plan`, verify that the saved plan still matches
    /// and exit.
    #[arg(long)]
    pub dry_run: bool,

    /// Deploy only if the current plan matches this `.kixplan` file from
    /// `kix plan --save`. Uses the planning flags recorded in the file and
    /// exits 4 without applying anything if the cluster state, builds, flags,
    /// refusals, reverted drift, or prune deletions have changed.
    #[arg(
        long = "plan",
        id = "saved_plan",
        value_name = "FILE",
        conflicts_with_all = ["current_activation", "operator"]
    )]
    pub saved_plan: Option<std::path::PathBuf>,

    /// Behavior on error: `stop` or `continue`. With `stop`, a deploy whose
    /// plan contains a refused write aborts before applying anything.
    #[arg(long, default_value = "stop")]
    pub on_error: OnError,

    /// Readiness timeout (e.g. "5m", "300s", or bare seconds)
    #[arg(long, value_parser = validate_timeout)]
    pub timeout: Option<String>,

    /// Delegate deployment to the Kix operator instead of applying directly
    /// (requires the build in the cluster's Nix store; incompatible with `--bundle`)
    #[arg(long, conflicts_with = "bundle")]
    pub operator: bool,

    /// Add a `KEY=VALUE` annotation to the Activation record (repeatable).
    /// Keys under `kix.run/`, its subdomains, or retired Kix domains are
    /// reserved and rejected.
    #[arg(
        long = "record-annotation",
        value_name = "KEY=VALUE",
        value_parser = parse_record_annotation,
        conflicts_with = "operator"
    )]
    pub record_annotations: Vec<(String, String)>,

    /// Render a live inline graph-streaming dashboard. Falls back to
    /// line-oriented output on non-interactive terminals.
    #[arg(long)]
    pub tui: bool,

    /// Group the tree view by namespace instead of Kix package. Only affects
    /// rendering; execution order is unchanged.
    #[arg(long)]
    pub group_by_ns: bool,

    /// Cap the live viewport height in rows. Default: half the terminal
    /// height (clamped to [10, 40]). Rows beyond the cap fold into the
    /// scrollback history above.
    #[arg(long, value_name = "ROWS")]
    pub fold_height: Option<u16>,

    /// Output format for the deploy event stream. `pretty` (default on TTY)
    /// is the colored human stream; `line` is the nix-build-L idiom (one
    /// line per terminal verdict, no ANSI); `json` emits NDJSON, one event
    /// per line, suitable for CI/automation. Non-TTY stdout auto-falls-back
    /// to `line` when `pretty` is requested.
    #[arg(long, value_enum, default_value_t = LogFormat::Pretty)]
    pub log_format: LogFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum LogFormat {
    Pretty,
    Line,
    Json,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OnError {
    Stop,
    Continue,
}

#[derive(clap::Args)]
pub struct RollbackArgs {
    /// Cluster name
    pub cluster: String,

    /// List available Superseded activations without rolling back.
    /// Shows name, identity-hash, timestamp, source store path, and the
    /// previousActivation link so the deploy chain is easy to follow.
    /// Respects `--output json|yaml` for machine consumption.
    #[arg(long)]
    pub list: bool,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview mode: show what would be applied without making changes
    #[arg(long)]
    pub dry_run: bool,

    /// Delete orphaned resources from the current activation or earlier deploys
    /// that are not in the rollback target
    #[arg(long)]
    pub prune: bool,

    /// Take ownership of fields that other field managers own, such as a
    /// replica count set with `kubectl scale`. Without this, the rollback
    /// stops before writing anything when the apiserver reports a conflict.
    #[arg(long)]
    pub force_conflicts: bool,

    /// Delegate rollback to the operator instead of applying directly
    #[arg(long)]
    pub operator: bool,
}

fn parse_record_annotation(s: &str) -> Result<(String, String), String> {
    let (key, value) = s
        .split_once('=')
        .ok_or_else(|| format!("expected KEY=VALUE, got '{s}'"))?;
    // Reserve Kix's own annotation domains (current and retired) for internal
    // metadata such as identity-hash and built-via.
    if key.is_empty() || kix::manifest::keys::is_kix_domain_key(key) {
        return Err(format!(
            "'{key}' is not allowed: the key must be set and not under {}",
            kix::manifest::keys::DOMAIN
        ));
    }
    Ok((key.to_string(), value.to_string()))
}

fn validate_timeout(s: &str) -> Result<String, String> {
    let err = || format!("invalid timeout: '{s}'. Use '5m', '300s', or a number of seconds");
    let s = s.trim();
    if let Some(n) = s.strip_suffix('m') {
        n.parse::<u64>().map_err(|_| err())?;
    } else if let Some(n) = s.strip_suffix('s') {
        n.parse::<u64>().map_err(|_| err())?;
    } else {
        s.parse::<u64>().map_err(|_| err())?;
    }
    Ok(s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_annotation_cannot_use_a_kix_key() {
        assert_eq!(
            parse_record_annotation("lithus.net/statement=abc=="),
            Ok(("lithus.net/statement".into(), "abc==".into()))
        );
        let domain = kix::manifest::keys::DOMAIN;
        let retired = kix::legacy_domain::DOMAINS[0];
        for refused in [
            format!("{}=x", kix::manifest::keys::IDENTITY_HASH),
            format!("deploy.{domain}/x=y"),
            format!("{retired}/built-via=/tmp"),
            "=x".to_string(),
            "no-equals".to_string(),
        ] {
            assert!(parse_record_annotation(&refused).is_err(), "{refused}");
        }
    }
}
