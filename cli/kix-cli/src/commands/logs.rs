//! Tail logs for a package's primary workload via `kubectl logs`.

use std::os::unix::process::CommandExt;
use std::process::Command;

use miette::{Result, miette};

use crate::cli::LogsArgs;
use crate::output;

use super::CommandContext;
use super::workload::resolve_package_workload;

pub fn run(args: &LogsArgs, ctx: &mut CommandContext) -> Result<()> {
    let target = resolve_package_workload(&ctx.global, &args.cluster, &args.package)?;

    crate::esay!(
        "  {} {} {} in {} (selector: {})",
        output::dim("→ kubectl logs for"),
        output::bold(&target.kind),
        output::bold(&target.name),
        output::bold(&target.namespace),
        output::dim(&target.selector),
    );

    let mut cmd = Command::new("kubectl");
    cmd.arg("logs");
    cmd.args(["-n", &target.namespace]);
    cmd.args(["-l", &target.selector]);
    // Stream from all matching pods by default so multi-replica workloads show
    // every replica's logs. Raise `--max-log-requests` above kubectl's default
    // of 5 so larger ReplicaSets do not drop pods.
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
        // kubectl ignores `--all-containers` when `-c` selects a specific container.
        cmd.args(["-c", container]);
    }
    if let Some(since) = args.since.as_deref() {
        cmd.args(["--since", since]);
    }
    if args.previous {
        cmd.arg("--previous");
    }

    // Replace the current process so SIGINT goes directly to kubectl.
    let err = cmd.exec();
    Err(miette!("could not start kubectl logs: {err}"))
}
