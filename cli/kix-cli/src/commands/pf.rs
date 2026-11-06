//! Port-forward to a package's primary workload.
//!
//! Shells out to `kubectl port-forward -n <ns> <kind>/<name> <ports...>`.
//! Targets the workload resource directly rather than a specific pod so
//! `kubectl` handles pod selection and re-selection on pod churn.

use std::os::unix::process::CommandExt;

use kix::runtime::{self, Tool, Want};
use miette::{Result, miette};

use crate::cli::PortForwardArgs;
use crate::output;

use super::CommandContext;
use super::workload::resolve_package_workload;

pub fn run(args: &PortForwardArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.ports.is_empty() {
        return Err(miette!(
            "no ports specified. Usage: kix pf <cluster> <package> <port> [<port>...] \
             (each port is LOCAL:REMOTE or a bare REMOTE)"
        ));
    }

    let target = resolve_package_workload(&ctx.global, &args.cluster, &args.package)?;

    crate::esay!(
        "  {} {} in {}; forwarding {}",
        output::dim("→ kubectl port-forward"),
        output::bold(&target.kubectl_ref()),
        output::bold(&target.namespace),
        output::bold(&args.ports.join(" ")),
    );

    let mut cmd = runtime::tool(Tool::Kubectl, Want::Shipped).map_err(|e| miette!("{e}"))?;
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
    Err(miette!("could not start kubectl port-forward: {err}"))
}
