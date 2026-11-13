//! Run the parsed command.
//!
//! Each command declares what it needs in [`Command::needs`], and [`run`]
//! sets that up before one `match` calls the command. Both are exhaustive
//! matches, so a new command does not compile until it says what it needs and
//! how it runs.

use miette::Result;

use crate::cli::{Cli, Command, MigrateCommand};
use crate::commands::{self, CommandContext};
use crate::exit::Exit;

/// What `main` sets up before a command runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Needs {
    /// Only the command line and a [`CommandContext`].
    ///
    /// The command must work where the others stop: outside a project, with
    /// a broken Kix runtime, or when the project does not evaluate. It loads
    /// `kix.toml` itself if it reads it.
    Nothing,
    /// A project: a valid cluster name, the Nix runner the project's builder
    /// in `kix.toml` chooses, and a Kix runtime from this release.
    Project,
}

impl Command {
    /// Return what the command needs before it runs.
    pub fn needs(&self) -> Needs {
        match self {
            // Runs another program in place of Kix.
            Command::Plugin(_) => Needs::Nothing,
            Command::Completions(_) => Needs::Nothing,
            // Installs and lists versions of Kix, inside a project or not.
            Command::SelfCmd(_) => Needs::Nothing,
            // Reports a broken runtime instead of stopping on it.
            Command::Doctor => Needs::Nothing,
            // Edits the pin file without evaluating the project, so it works
            // when evaluation fails.
            Command::Pin(_) => Needs::Nothing,
            // Runs every evaluation in the Kix version of each step.
            Command::Upgrade(_) => Needs::Nothing,
            // Reads only the cluster, so it works from a bare kubeconfig
            // outside any project.
            Command::Drift(_) => Needs::Nothing,
            // Reads only the SOPS file it is given.
            Command::Secret(_) => Needs::Nothing,
            Command::Lib(_)
            | Command::Build(_)
            | Command::Diff(_)
            | Command::Plan(_)
            | Command::Check(_)
            | Command::Deploy(_)
            | Command::Status(_)
            | Command::List(_)
            | Command::Graph(_)
            | Command::Bundle(_)
            | Command::Inspect(_)
            | Command::Gc(_)
            | Command::Migrate(_)
            | Command::Rollback(_)
            | Command::Export(_)
            | Command::Logs(_)
            | Command::Pf(_)
            | Command::Health(_)
            | Command::Images(_)
            | Command::Snapshot(_)
            | Command::Compliance(_) => Needs::Project,
        }
    }
}

/// Set up what the command needs, run it, and return how `kix` ends.
pub fn run(cli: &Cli) -> Result<Exit> {
    if cli.command.needs() == Needs::Project {
        prepare_project(cli)?;
    }
    let mut ctx = CommandContext::new(
        &cli.global,
        &commands::compliance::receipt::ComplianceReceipts,
    );
    let ctx = &mut ctx;
    let global = &cli.global;
    match &cli.command {
        Command::Plugin(args) => crate::plugin::run(args, global),
        Command::Completions(args) => commands::completions::run(args, global).map(Exit::from),
        Command::SelfCmd(command) => commands::self_cmd::run(command).map(Exit::from),
        Command::Doctor => commands::doctor::run(global).map(Exit::from),
        Command::Pin(command) => commands::pin::run(command, ctx),
        Command::Upgrade(args) => commands::upgrade::run(args, global).map(Exit::from),
        Command::Drift(args) => commands::drift::run(args, ctx),
        Command::Secret(command) => commands::secret::run(command).map(Exit::from),
        Command::Lib(command) => commands::library::run(command, global).map(Exit::from),
        Command::Build(args) => commands::build::run(args, ctx).map(Exit::from),
        Command::Diff(args) => commands::diff::run(args, ctx),
        Command::Plan(args) => commands::plan::run(&args.plan, args.save.as_deref(), ctx),
        Command::Check(args) => commands::check::run(args, ctx),
        Command::Deploy(args) => commands::deploy::run(args, ctx),
        Command::Status(args) => commands::status::run(args, ctx).map(Exit::from),
        Command::List(args) => commands::list::run(args, ctx).map(Exit::from),
        Command::Graph(args) => commands::graph::run(args, ctx).map(Exit::from),
        Command::Bundle(args) => commands::bundle::run(args, ctx).map(Exit::from),
        Command::Inspect(args) => commands::inspect::run(args, ctx).map(Exit::from),
        Command::Gc(args) => commands::gc::run(args, ctx).map(Exit::from),
        Command::Migrate(MigrateCommand::Domain(args)) => {
            commands::migrate::run(args, ctx).map(Exit::from)
        }
        Command::Rollback(args) => commands::rollback::run(args, ctx),
        Command::Export(args) => commands::export::run(args, ctx).map(Exit::from),
        Command::Logs(args) => commands::logs::run(args, ctx).map(Exit::from),
        Command::Pf(args) => commands::pf::run(args, ctx).map(Exit::from),
        Command::Health(args) => commands::health::run(args, ctx),
        Command::Images(args) => commands::images::run(args, ctx).map(Exit::from),
        Command::Snapshot(args) => commands::snapshot::run(args, ctx).map(Exit::from),
        Command::Compliance(args) => commands::compliance::run(args, ctx).map(Exit::from),
    }
}

/// Check and set up the project for a [`Needs::Project`] command, cheapest
/// check first.
fn prepare_project(cli: &Cli) -> Result<()> {
    // A deploy waits for a person to acknowledge each change to stored data
    // that the last `kix upgrade` found.
    if let Command::Deploy(args) = &cli.command
        && !args.dry_run
        && let Some(dir) = commands::project_dir(&cli.global.flake)
    {
        commands::upgrade::check_deploy(&dir)?;
    }
    // Validate the cluster name before the Nix backend starts, which is slow.
    if let Some(name) = cli.command.cluster_name() {
        validate_cluster_name(name)?;
    }
    // The project's builder decides which Nix every later step runs.
    commands::select_builder(&cli.global)?;
    // Stop before any work when Kix has no runtime, or its runtime comes from
    // another release.
    kix::runtime::runtime().map_err(|e| miette::miette!("{e}"))?;
    Ok(())
}

/// Validate cluster name format.
///
/// SECURITY: This is the primary defense against Nix expression injection.
/// The cluster name is spliced into the flake attribute `nix eval` reads
/// (`kix::eval::nix`) and into the `--apply` expression of `nix eval`
/// (`cluster_name_command`).
/// Only alphanumeric characters, hyphens, and underscores are safe.
fn validate_cluster_name(name: &str) -> Result<()> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err(miette::miette!(
            "'{}' is not a valid cluster name. Use a name like 'example' or 'nw1', not a file path.",
            name
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    fn needs(args: &[&str]) -> Needs {
        let matches = crate::cli::command()
            .try_get_matches_from(args)
            .expect("arguments parse");
        Cli::from_arg_matches(&matches)
            .expect("arguments convert")
            .command
            .needs()
    }

    /// These commands must run where a project cannot be loaded, so none of
    /// them may wait for the project's builder or the Kix runtime.
    #[test]
    fn commands_that_must_work_without_a_project_need_nothing() {
        for args in [
            &["kix", "drift"][..],
            &["kix", "pin", "list"],
            &["kix", "upgrade"],
            &["kix", "doctor"],
            &["kix", "self", "list"],
            &["kix", "secret", "hash", "f.sops.yaml"],
            &["kix", "completions", "bash"],
            &["kix", "some-plugin"],
        ] {
            assert_eq!(needs(args), Needs::Nothing, "{args:?}");
        }
    }

    #[test]
    fn commands_that_build_need_the_project() {
        for args in [
            &["kix", "build", "c"][..],
            &["kix", "plan", "c"],
            &["kix", "deploy", "c"],
            &["kix", "lib", "update"],
            &["kix", "list", "clusters"],
        ] {
            assert_eq!(needs(args), Needs::Project, "{args:?}");
        }
    }

    #[test]
    fn a_cluster_name_is_a_plain_word() {
        assert!(validate_cluster_name("nw1").is_ok());
        assert!(validate_cluster_name("homelab-kind_2").is_ok());
        for bad in ["", "../x", "a.b", "a b", "x\"; builtins.exec"] {
            assert!(validate_cluster_name(bad).is_err(), "{bad}");
        }
    }
}
