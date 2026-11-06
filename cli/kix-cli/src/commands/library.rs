//! `kix lib update`: move a project's Kix library to this program's release.

use kix::library::{self, LibraryVersion};
use miette::{Result, miette};

use crate::cli::{GlobalArgs, LibCommand};

pub fn run(command: &LibCommand, global: &GlobalArgs) -> Result<()> {
    match command {
        LibCommand::Update(args) => {
            let updated =
                library::update(&global.flake, args.dry_run).map_err(|e| miette!("{e}"))?;
            if !updated.changed {
                println!("Kix library is already {}.", updated.to);
                return Ok(());
            }
            let from = match &updated.from {
                LibraryVersion::Known(v) => v.as_str(),
                LibraryVersion::Older => "an older version",
                LibraryVersion::Unknown => "an unknown version",
            };
            if args.dry_run {
                println!(
                    "Kix library: {from} -> {}. This was a dry run, so flake.lock is unchanged.",
                    updated.to
                );
            } else {
                println!(
                    "Kix library: {from} -> {}. Commit flake.lock to share this with your team.",
                    updated.to
                );
            }
            Ok(())
        }
    }
}
