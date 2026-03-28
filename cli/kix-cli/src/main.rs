mod cli;
mod commands;
mod output;
mod plan;

use clap::Parser;
use cli::{Cli, Command};

/// Validate cluster name format.
///
/// SECURITY: This is the primary defense against Nix expression injection.
/// The cluster name is interpolated into Nix eval strings in kix-eval's FFI layer.
/// Only alphanumeric characters, hyphens, and underscores are safe.
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

/// Initialize tracing subscriber based on verbosity flags.
///
/// KIX_LOG env var overrides the verbose-derived filter (like RUST_LOG).
fn init_tracing(verbose: u8, quiet: bool) {
    use tracing_subscriber::EnvFilter;

    let filter = if let Ok(env_filter) = std::env::var("KIX_LOG") {
        EnvFilter::new(env_filter)
    } else if quiet {
        EnvFilter::new("error")
    } else {
        match verbose {
            0 => EnvFilter::new("warn"),
            1 => EnvFilter::new("kix=info"),
            2 => EnvFilter::new("kix=debug"),
            _ => EnvFilter::new("debug"),
        }
    };

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_timer(tracing_subscriber::fmt::time::uptime())
        .init();
}

fn main() -> miette::Result<()> {
    miette::set_hook(Box::new(|_| {
        Box::new(miette::MietteHandlerOpts::new().build())
    }))?;

    let cli = Cli::parse();
    init_tracing(cli.global.verbose, cli.global.quiet);
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
        Command::Gc(args) => commands::gc::run(args, &mut ctx),
        Command::Health(args) => commands::health::run(args, &mut ctx),
        Command::Snapshot(args) => commands::snapshot::run(args, &mut ctx),
        Command::Completions(_) => unreachable!(),
    }
}
