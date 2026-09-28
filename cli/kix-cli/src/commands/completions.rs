use clap_complete::generate;
use miette::Result;

use crate::cli::{CompletionsArgs, GlobalArgs};

pub fn run(args: &CompletionsArgs, _global: &GlobalArgs) -> Result<()> {
    let mut cmd = crate::cli::command();
    generate(args.shell, &mut cmd, "kix", &mut std::io::stdout());
    Ok(())
}
