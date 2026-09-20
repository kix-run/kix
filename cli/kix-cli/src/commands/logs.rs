//! Tail logs for a package's primary workload.
//!
//! Shells out to `kubectl logs -n <ns> -l <selector>`. The point of this
//! command is a convenience wrapper around kubectl.

use std::os::unix::process::CommandExt;
use std::process::Command;

use miette::{Result, miette};

use crate::cli::LogsArgs;
use crate::output;

use super::CommandContext;
use super::workload::{resolve_flake_path, resolve_package_workload};

pub fn run(args: &LogsArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;
    let target = resolve_package_workload(
        &flake_path,
        &args.cluster,
        &args.package,
        &ctx.global.input_overrides(),
        ctx.global.quiet,
    )?;

    if !ctx.global.quiet {
        eprintln!(
            "  {} {} {} in {} (selector: {})",
            output::dim("→ kubectl logs for"),
            output::bold(&target.kind),
            output::bold(&target.name),
            output::bold(&target.namespace),
            output::dim(&target.selector),
        );
    }

    let mut cmd = Command::new("kubectl");
    cmd.arg("logs");
    cmd.args(["-n", &target.namespace]);
    cmd.args(["-l", &target.selector]);
    // Multi-pod: default to streaming from all matching pods so the user
    // sees every replica's logs. --max-log-requests raises kubectl's default
    // ceiling of 5 so large ReplicaSets don't drop pods.
    cmd.arg("--all-containers=true");
    cmd.args(["--max-log-requests", "20"]);
    cmd.arg("--prefix=true");

    if let Some(ctx_name) = ctx.global.context.as_deref() {
        cmd.args(["--context", ctx_name]);
    }
    if args.follow {
        cmd.arg("-f");
    }
    if let Some(tail) = args.tail {
        cmd.args(["--tail", &tail.to_string()]);
    }
    if let Some(container) = args.container.as_deref() {
        // When --container is set, --all-containers is ignored by kubectl;
        // kubectl ignores --all-containers when a container is selected.
        cmd.args(["-c", container]);
    }
    if let Some(since) = args.since.as_deref() {
        cmd.args(["--since", since]);
    }
    if args.previous {
        cmd.arg("--previous");
    }

    // `exec` replaces this process so Ctrl-C / SIGINT goes straight to
    // kubectl instead of being intercepted here. On Unix this never
    // returns on success.
    let err = cmd.exec();
    Err(miette!("could not start kubectl logs: {err}"))
}
