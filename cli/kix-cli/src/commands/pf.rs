//! `kix pf <package> <port>` — port-forward to a package's primary workload.
//!
//! Shells out to `kubectl port-forward -n <ns> <kind>/<name> <ports...>`.
//! Uses the workload resource directly (not the matching pod) so kubectl
//! handles pod selection and re-selection on pod churn.
//! See `v2_discussions/84_m0_m1_implementation_plan.md` §4.

use std::os::unix::process::CommandExt;
use std::process::Command;

use miette::{Result, miette};

use crate::cli::PortForwardArgs;
use crate::output;

use super::CommandContext;
use super::workload::{resolve_flake_path, resolve_package_workload};

pub fn run(args: &PortForwardArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.ports.is_empty() {
        return Err(miette!(
            "no ports specified. Usage: kix pf <cluster> <package> <port> [<port>...] \
             (each port is LOCAL:REMOTE or a bare REMOTE)"
        ));
    }

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
            "  {} {} in {} — forwarding {}",
            output::dim("→ kubectl port-forward"),
            output::bold(&target.kubectl_ref()),
            output::bold(&target.namespace),
            output::bold(&args.ports.join(" ")),
        );
    }

    let mut cmd = Command::new("kubectl");
    cmd.arg("port-forward");
    cmd.args(["-n", &target.namespace]);
    cmd.arg(target.kubectl_ref());
    for port in &args.ports {
        cmd.arg(port);
    }

    if let Some(ctx_name) = ctx.global.context.as_deref() {
        cmd.args(["--context", ctx_name]);
    }
    if let Some(addr) = args.address.as_deref() {
        cmd.args(["--address", addr]);
    }

    let err = cmd.exec();
    Err(miette!("failed to exec kubectl port-forward: {err}"))
}
