//! Arguments of the commands that manage the project and Kix itself: `upgrade`,
//! `lib`, `secret`, `self`, and `completions`.

use clap::Subcommand;
use clap_complete::Shell;
use std::path::PathBuf;

#[derive(clap::Args)]
pub struct UpgradeArgs {
    /// The version to move to: an exact version such as 0.12.1, a minor such as
    /// 0.12 (its newest patch), or `latest`
    #[arg(long, value_name = "VERSION")]
    pub to: Option<String>,

    /// Print the target version and the release notes in the range with likely
    /// matches marked, and change nothing
    #[arg(long)]
    pub preview: bool,

    /// Acknowledge a data migration by its id or name so `kix deploy` goes ahead, and
    /// do nothing else
    #[arg(long, value_name = "ID", num_args = 1.., conflicts_with_all = ["to", "preview"])]
    pub ack: Vec<String>,
}

/// Manage the Kix library this project pins in flake.lock.
#[derive(Subcommand)]
pub enum LibCommand {
    /// Move this project's Kix library to the version of the installed Kix
    ///
    /// Locks the project's Kix library input (github:kix-run/kix) to the
    /// tag `v<version>` of the installed Kix and writes flake.lock. It
    /// does not change flake.nix. When flake.nix pins another release, or the
    /// input is a local path or a fork, it says what to change by hand.
    Update(LibUpdateArgs),
}

/// Work with the SOPS files that Secrets are made from.
#[derive(Subcommand)]
pub enum SecretCommand {
    /// Print the `hash` of a SOPS file's values
    ///
    /// Decrypts FILE with the sops in the Kix runtime, as `kix deploy` does,
    /// and prints the value to set as `hash` beside `source` on a secret
    /// instance or in `scope.mkSecret`. It prints only the hash, never the
    /// values. Decrypting needs the same key that `kix deploy` uses.
    Hash {
        /// The SOPS file, such as secrets/app-db.sops.yaml
        file: PathBuf,
    },
}

/// Install, list, and remove versions of Kix.
#[derive(Subcommand)]
pub enum SelfCommand {
    /// Install a version of Kix
    ///
    /// Takes a minor such as 0.8, which installs its newest patch, or an
    /// exact version such as 0.8.3. Kix checks the release's signature and
    /// SHA-256 before it unpacks anything.
    Install {
        /// The version to install, such as 0.8 or 0.8.3
        version: String,
    },

    /// List the installed versions, newest first
    ///
    /// Marks the running version with `*` and the one `kix` on PATH runs.
    List,

    /// Remove all but the newest installed versions
    ///
    /// Always keeps the running version and the one `kix` on PATH runs.
    Prune {
        /// How many of the newest versions to keep
        #[arg(long, default_value_t = 2)]
        keep: usize,

        /// Show what would be removed without removing it
        #[arg(long)]
        dry_run: bool,
    },

    /// Install the newest release and point ~/.local/bin/kix at it
    ///
    /// Works when the install script installed this Kix. Otherwise it says
    /// how to upgrade Kix the way it was installed.
    Update,
}

#[derive(clap::Args)]
pub struct LibUpdateArgs {
    /// Show what would change without writing flake.lock
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(clap::Args)]
pub struct CompletionsArgs {
    /// Shell to generate completions for
    pub shell: Shell,
}
