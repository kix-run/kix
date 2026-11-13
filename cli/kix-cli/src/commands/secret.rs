//! `kix secret hash`: print the `hash` of a SOPS file's values.

use miette::{Result, miette};

use crate::cli::SecretCommand;

pub fn run(command: &SecretCommand) -> Result<()> {
    match command {
        SecretCommand::Hash { file } => {
            if !file.is_file() {
                return Err(miette!("SOPS file {} not found", file.display()));
            }
            let hash = kix::cluster::sops_file_hash(file).map_err(|e| miette!("{e}"))?;
            println!("{hash}");
            Ok(())
        }
    }
}
