//! Arguments of `kix deploy`, `kix rollback`, and `kix history`.

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
    /// `kix plan --out`. Uses the planning flags recorded in the file and
    /// exits 4 without applying anything if the cluster state, builds, flags,
    /// refusals, reverted drift, or prune deletions have changed.
    #[arg(
        long = "plan",
        id = "saved_plan",
        value_name = "FILE",
        conflicts_with_all = ["offline", "operator"]
    )]
    pub saved_plan: Option<std::path::PathBuf>,

    /// Behavior on error: `stop` or `continue`. With `stop`, a deploy whose
    /// plan contains a refused write aborts before applying anything.
    #[arg(long, default_value = "stop")]
    pub on_error: OnError,

    /// Timeout for readiness and for each delete without finalizer progress,
    /// up to 5m per delete (e.g. "5m", "300s", or bare seconds)
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

    /// How to show the deploy's progress. `pretty` (default on a terminal)
    /// is the colored stream for a person; `line` prints one line per
    /// finished object, without color; `json` prints one JSON event per line,
    /// for CI and other programs; `tui` draws a live view of the dependency
    /// graph. When stdout is not a terminal, `pretty` and `tui` print `line`
    /// output. The height of the `tui` view is half the terminal height
    /// (10 to 40 rows), or `KIX_TUI_HEIGHT` rows when that is set.
    #[arg(long, value_enum, default_value_t = LogFormat::Pretty)]
    pub log_format: LogFormat,

    /// Group the `tui` view by Kix package or by namespace. Only changes the
    /// display, not the order of the deploy.
    #[arg(long, value_enum, default_value_t = GroupBy::Package)]
    pub group_by: GroupBy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum LogFormat {
    Pretty,
    Line,
    Json,
    Tui,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum GroupBy {
    Package,
    Namespace,
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

    /// Acknowledge detected stateful migration pairs. Without this flag, a
    /// rollback that would remove an object that holds data from a stateful
    /// package and add another in its place is rejected (even with --yes)
    /// to prevent silent data loss. Kix does not copy data between them.
    #[arg(long)]
    pub accept_migrations: bool,

    /// Delegate rollback to the operator instead of applying directly
    #[arg(long)]
    pub operator: bool,
}

#[derive(clap::Args)]
pub struct HistoryArgs {
    /// Cluster name
    pub cluster: String,
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

pub(crate) fn validate_timeout(s: &str) -> Result<String, String> {
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
