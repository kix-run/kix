use clap::CommandFactory;
use clap_complete::generate;
use miette::Result;

use crate::cli::{Cli, CompletionsArgs, GlobalArgs};

pub fn run(args: &CompletionsArgs, _global: &GlobalArgs) -> Result<()> {
    let mut cmd = Cli::command();
    generate(args.shell, &mut cmd, "kix", &mut std::io::stdout());
    Ok(())
}
