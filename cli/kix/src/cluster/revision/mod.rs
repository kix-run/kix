//! `PackageInstanceRevision`: what one build makes for one package
//! instance, the cluster level, or the objects a deploy kept, and the hash
//! each object had when Kix last applied it.
//!
//! - A revision's `spec` lists the build hash, group, kind, namespace, and
//!   name of each object, and the objects it depends on by name (`needs`).
//!   For an instance it also holds the lifecycle of the instance's package.
//!   Kubernetes refuses a change to `spec`.
//! - Format 1, which an earlier build of Kix wrote, has no `needs` and no
//!   lifecycle. Kix still reads it, and takes the edges of an object that
//!   only a format 1 revision names from the object's `kix.run/depends-on`
//!   annotation ([`crate::cluster::edges`]).
//! - The name is the Kix cluster's name and a hash of `spec`
//!   ([`name_of`]), so two machines that hold the same build compute the
//!   same name, and a deploy that leaves an instance unchanged names the
//!   revision the deploy before it created. A read checks the hash against
//!   `spec`.
//! - `status.applied` maps each object's build hash to the hash of what Kix
//!   applied.
//! - Revisions are cluster-scoped and labelled with their Kix cluster, so one
//!   list request returns every revision of a Kix cluster.
//!
//! - An Activation record names its revisions in `status.revisions`
//!   ([`RevisionMap`]). A revision stays while a record that Kix needs names
//!   it ([`keep::needed`]), and a lock holder deletes the rest
//!   ([`keep::clean`]).
//!
//! The CRD is part of the Kix program, which installs it with Kix's other
//! own CRDs ([`crate::cluster::own_crds`]).

pub mod applied;
pub mod convert;
pub(crate) mod crd;
pub mod keep;
mod map;
mod spec;
mod store;
#[cfg(test)]
mod tests;

use kube::Client;
use kube::api::{Api, DynamicObject};
use kube::discovery::ApiResource;

use crate::manifest::keys;

pub use applied::AppliedHashes;
pub use convert::Conversion;
pub use map::{RevisionMap, UnreadableMap};
pub use spec::{
    AppliedKey, FORMAT, MAX_BYTES, Need, ReadError, Revision, RevisionObject, RevisionSet,
    RevisionSpec, Slot, TooLarge, name_of,
};
pub use store::{Created, Listed, RevisionError, Revisions};

/// The kind of a revision.
pub const KIND: &str = "PackageInstanceRevision";

/// The plural the API serves revisions under.
pub const PLURAL: &str = "packageinstancerevisions";

/// Return the name of the revisions' CustomResourceDefinition.
pub fn crd_name() -> String {
    format!("{PLURAL}.{}", keys::GROUP)
}

fn version() -> &'static str {
    keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v)
}

fn resource() -> ApiResource {
    ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(keys::GROUP, version(), KIND),
        PLURAL,
    )
}

fn api(client: &Client) -> Api<DynamicObject> {
    Api::all_with(client.clone(), &resource())
}
