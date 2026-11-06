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
        "this flake defines no Kix outputs (no {attr}). Run kix in a directory whose flake.nix uses kix.lib.mkFlake, or pass --flake <path>"
    )]
    NoKixOutputs { attr: String },

    /// The cluster exists, but its Kix library is older than this binary
    /// and writes no `activationIndex`.
    #[error(
        "cluster '{cluster}' uses a Kix library older than this kix binary. The library does not write the activation index that this kix reads. Run `kix lib update` to move flake.lock to this kix release, or use the kix binary of the library's release"
    )]
    NoActivationIndex { cluster: String },

    #[error("could not access the Nix evaluation cache: {source}")]
    CacheError {
        #[source]
        source: anyhow::Error,
    },

    #[error("could not read the built resources and their dependencies: {message}")]
    StoreGraphError { message: String },

    #[error(transparent)]
    Nix(#[from] super::nix::NixCommandError),

    #[error(transparent)]
    Helm(#[from] super::helm::HelmError),

    /// A manifest or package index in the build could not be parsed as strict JSON.
    #[error("could not read the built resources and their dependencies: {0}")]
    NotJson(#[from] super::manifest_json::NotJson),
}

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
        "this flake has no Kix outputs for {system}, the system this kix binary runs on. \
         It has them for {}. Add {system} to the systems the flake builds for: \
         pass systems = [ {systems} ] to kix.lib.mkFlake, or add {system} to the \
         systems your flake calls kix.lib.forPkgs for",
        provided.join(", ")
    )
}
