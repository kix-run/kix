//! The CustomResourceDefinitions of Kix's own kinds, which the Kix program
//! installs and updates itself: Activation, PackageInstance, ActivationHead,
//! and PackageInstanceRevision.
//!
//! Each definition has a number that goes up by one whenever its content
//! changes. [`ensure_all`] writes the number on the CRD in
//! [`keys::DEFINITION`](crate::manifest::keys::DEFINITION), with the CRD's
//! `metadata.generation` after the write. Kubernetes raises the generation on
//! every change to `spec`, so a generation that moved means someone outside
//! Kix changed the CRD, and the number no longer describes it. A CRD with no
//! number, or one whose number is void, holds number 1. [`decide`] then picks
//! what to do with it.
//!
//! - Number 1 of Activation and PackageInstance is exactly what builds of
//!   earlier releases apply, so an older Kix that applies them from a build
//!   changes nothing. Raise either number only once no supported release
//!   applies them from a build.
//! - Change a definition's content only together with a new number, and
//!   update its content hash in the tests. A new number may add fields,
//!   printer columns, and optional validation. It may not add a required
//!   field, narrow a type, or stop serving a version, because objects that
//!   older releases stored must stay readable. A change that must do one of
//!   those needs a required stop.

mod definitions;
mod ensure;
#[cfg(test)]
mod tests;

use serde_json::Value;

pub use ensure::{Action, CrdError, Live, decide, ensure_all};

/// A CustomResourceDefinition that the Kix program carries and installs
/// itself.
#[derive(Debug, Clone)]
pub struct OwnCrd {
    /// The definition's name, `<plural>.<group>`.
    pub name: String,
    /// The definition, as Kix installs it.
    pub definition: Value,
    /// Which of Kix's definitions of the kind this is. It goes up by one
    /// whenever the content changes.
    pub number: u32,
    /// What Kix keeps in objects of the kind, completing "the definition
    /// for ...", such as `the deploy lock`.
    pub holds: &'static str,
    /// The permissions an account needs on the kind, as a sentence names
    /// them.
    pub verbs: &'static str,
}

/// Return every CustomResourceDefinition the Kix program installs.
pub fn all() -> [OwnCrd; 4] {
    [
        OwnCrd {
            name: crate::manifest::keys::ACTIVATIONS_CRD.to_string(),
            definition: definitions::activation(),
            number: 1,
            holds: "deployment records",
            verbs: "`get`, `list`, `watch`, `create`, `patch`, and `delete` (plus `patch` on `status`)",
        },
        OwnCrd {
            name: crate::manifest::keys::PACKAGE_INSTANCES_CRD.to_string(),
            definition: definitions::package_instance(),
            number: 1,
            holds: "package instances",
            verbs: "`get`, `list`, `patch`, and `delete`",
        },
        OwnCrd {
            name: crate::cluster::head::crd_name(),
            definition: crate::cluster::head::crd::definition(),
            number: 1,
            holds: "the deploy lock",
            verbs: "`get`, `list`, `create`, and `update`",
        },
        OwnCrd {
            name: crate::cluster::revision::crd_name(),
            definition: crate::cluster::revision::crd::definition(),
            number: 1,
            holds: "deployed object lists",
            verbs: "`get`, `list`, `create`, and `delete` (plus `patch` on `status`)",
        },
    ]
}
