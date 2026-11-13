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
            let moved = match &updated.from {
                LibraryVersion::Known(v) => format!("{v} -> {}", updated.to),
                LibraryVersion::Older => format!("an older version -> {}", updated.to),
                LibraryVersion::Unknown => updated.to.clone(),
            };
            if args.dry_run {
                println!("Kix library: {moved}. This was a dry run, so flake.lock is unchanged.");
            } else {
                println!("Kix library: {moved}. Commit flake.lock to share this with your team.");
            }
            Ok(())
        }
    }
}
