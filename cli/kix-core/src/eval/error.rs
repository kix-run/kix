//! Error types for Nix evaluation.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum KixEvalError {
    #[error(
        "cluster '{name}' was not found. Run `kix list clusters` with the same flake to see available clusters"
    )]
    ClusterNotFound { name: String },

    /// The flake provides its outputs for `provided` and not for `system`,
    /// the system this binary looks them up under.
    #[error("{}", system_not_provided_message(.system, .provided))]
    SystemNotProvided {
        system: String,
        provided: Vec<String>,
    },

    /// The flake has no `attr` output for this binary's system and provides
    /// nothing for any other system either.
    #[error(
        "this flake defines no Kix clusters (no `{attr}` output in `flake.nix`)\n  \
         No project files or cluster resources were changed.\n\n  \
         Why:\n    \
         The `flake.nix` in the current directory (or at the path passed to `--flake`) does not export `{attr}`, which `kix.lib.mkFlake` creates.\n\n  \
         Next (choose one):\n    \
         - Change into the directory that holds your Kix project's `flake.nix` (or pass `--flake <path>`) and run the command again.\n    \
         - If this directory is your Kix project, check that `flake.nix` creates its outputs with `kix.lib.mkFlake`."
    )]
    NoKixOutputs { attr: String },

    /// The cluster exists, but its Kix library is older than this binary
    /// and writes no `activationIndex`.
    #[error(
        "cluster '{cluster}' uses a Kix library older than Kix {kix}\n  \
         No project files or cluster resources were changed.\n\n  \
         Next (choose one):\n    \
         - Run `kix lib update` to move the project to the {kix} library and commit `flake.lock`.\n    \
         - {KEEP_LIBRARY}",
        kix = crate::version::running().release()
    )]
    NoActivationIndex { cluster: String },

    #[error("could not read the built resources and their dependencies: {message}")]
    StoreGraphError { message: String },

    /// A check that only a bug in Kix (or, with `library`, in the Kix
    /// library) can fail. `detail` is for the maintainers.
    #[error(
        "internal error in Kix: {summary}\n  \
         This is a bug in Kix{}. No project files or cluster resources were changed.\n\n  \
         Detail:\n    \
         {detail}\n\n  \
         Next:\n    \
         {REPORT_A_BUG}",
        if *library { " or the Kix library" } else { "" }
    )]
    Internal {
        summary: &'static str,
        library: bool,
        detail: String,
    },

    #[error(transparent)]
    Nix(#[from] super::nix::NixCommandError),

    /// The machine's Nix refused to build a Helm chart during evaluation.
    #[error(
        "cannot render Helm charts with the `nix` builder (`builder = \"nix\"` in kix.toml) because `allow-import-from-derivation` is off in this machine's Nix. Set `allow-import-from-derivation = true` in nix.conf"
    )]
    ImportFromDerivationDisabled,

    /// Under the nix builder, evaluation reached a chart that only the kix
    /// builder renders. The library's nix route should never produce one.
    #[error(
        "internal error: under the `nix` builder, evaluation reached a Helm chart for the `kix` builder ({path}). This is a bug in Kix. Please report it with the output of `kix -v`"
    )]
    PlaceholderUnderNix { path: String },

    #[error(transparent)]
    Project(#[from] crate::project::ProjectMismatch),

    /// The project's Kix library is a version this Kix cannot build.
    #[error(transparent)]
    LibraryIncompatible(Box<crate::version::policy::LibraryIncompatible>),

    #[error(transparent)]
    Helm(#[from] super::helm::HelmError),

    /// A manifest or package index in the build could not be parsed as strict JSON.
    #[error("could not read the built resources and their dependencies: {0}")]
    NotJson(#[from] super::manifest_json::NotJson),
}

/// The choice, in a library mismatch, to keep the project's Kix library.
pub(crate) const KEEP_LIBRARY: &str = "To keep this project on its current Kix library instead, set `kix = \"<major.minor>\"` in `kix.toml` (using the Kix library's minor version, such as `\"0.8\"`).";

/// The next step after an error that reports a bug in Kix.
pub const REPORT_A_BUG: &str = "Run your command again with `-v` to capture the full trace and report the output to the Kix maintainers.";

impl KixEvalError {
    pub(crate) fn not_found(name: impl Into<String>) -> Self {
        Self::ClusterNotFound { name: name.into() }
    }
}

/// Write the message for [`KixEvalError::SystemNotProvided`], with the
/// `systems` list the user can paste into their `kix.lib.mkFlake` call.
fn system_not_provided_message(system: &str, provided: &[String]) -> String {
    let systems = provided
        .iter()
        .map(String::as_str)
        .chain(std::iter::once(system))
        .map(|s| format!("\"{s}\""))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "this flake has no Kix outputs for {system} (this machine's system). \
         It has them for {}. Add {system} to the systems the flake builds for: \
         pass systems = [ {systems} ] to kix.lib.mkFlake, or add {system} to the \
         systems your flake calls kix.lib.forPkgs for",
        provided.join(", ")
    )
}
