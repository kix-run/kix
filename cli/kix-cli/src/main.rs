mod cli;
mod commands;
mod output;

use clap::Parser;
use cli::{Cli, Command};

/// Validate that a cluster name is a valid Nix attribute identifier.
/// Rejects file paths, dots, slashes — anything that isn't alphanumeric/hyphens/underscores.
fn validate_cluster_name(name: &str) -> miette::Result<()> {
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

fn main() -> miette::Result<()> {
    miette::set_hook(Box::new(|_| {
        Box::new(miette::MietteHandlerOpts::new().build())
    }))?;

    let cli = Cli::parse();
    output::init_color(&cli.global);

    // Completions doesn't need a CommandContext (no evaluator, no runtime)
    if let Command::Completions(args) = &cli.command {
        return commands::completions::run(args, &cli.global);
    }

    // Validate cluster names before initializing the Nix backend (which is slow).
    if let Some(name) = cli.command.cluster_name() {
        validate_cluster_name(name)?;
    }

    let mut ctx = commands::CommandContext::new(&cli.global)?;

    match &cli.command {
        Command::Build(args) => commands::build::run(args, &mut ctx),
        Command::Diff(args) => commands::diff::run(args, &mut ctx),
        Command::Check(args) => commands::check::run(args, &mut ctx),
        Command::Deploy(args) => commands::deploy::run(args, &mut ctx),
        Command::Status(args) => commands::status::run(args, &mut ctx),
        Command::List(args) => commands::list::run(args, &mut ctx),
        Command::Graph(args) => commands::graph::run(args, &mut ctx),
        Command::Inspect(args) => commands::inspect::run(args, &mut ctx),
        Command::Snapshot(args) => commands::snapshot::run(args, &mut ctx),
        Command::Completions(_) => unreachable!(),
    }
}
