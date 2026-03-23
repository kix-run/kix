mod cli;
mod commands;
mod output;

use clap::Parser;
use cli::{Cli, Command};

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
