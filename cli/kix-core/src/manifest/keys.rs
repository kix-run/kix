//! The Kubernetes domain Kix owns, and the annotations, labels, and API names
//! built on it that the CLI and operator read or write. Keys that only the Nix
//! library writes are listed in `kix/lib/core/annotations.nix`.
//!
//! # One literal
//!
//! The domain is spelled exactly once in this crate, in `domain!`. Every key
//! is built from it with `key!`, so a rename is a one-line change here.
//! A test in this module walks the source tree and fails if any other file
//! spells a Kix domain, so the invariant cannot rot.
//!
//! # Reading versus writing
//!
//! **Writes use the constant.** `annotations.insert(keys::PACKAGE.into(), ...)`.
//!
//! **Reads go through [`get`] / [`get_meta`] / [`contains_meta`].** They are
//! plain lookups today. They are the single place a fallback to a retired
//! domain is added when the domain moves, so every reader inherits it at
//! once. A direct `annotations.get(PACKAGE)` on a live object would then
//! silently miss an old key and report the resource unstamped, which is how
//! a deploy would decide to re-create something that already exists.
//!
//! Manifests that Kix has just rendered or just stamped carry the current
//! domain by construction; reading those with the constant is fine.

use std::collections::BTreeMap;

use serde_json::Value;

/// The one place the domain is spelled.
///
/// A macro rather than a `const` because [`concat!`] needs a literal, and
/// every key below is a compile-time constant.
macro_rules! domain {
    () => {
        "kix.run"
    };
}

/// Build a Kix key at compile time: `key!("identity-hash")` is
/// `"<domain>/identity-hash"`.
macro_rules! key {
    ($name:literal) => {
        concat!(domain!(), "/", $name)
    };
}

/// The DNS domain that prefixes every key Kix stamps, and the group of the
/// CRDs Kix owns.
pub const DOMAIN: &str = domain!();

/// The API group of the Activation and PackageInstance CRDs. The same string
/// as [`DOMAIN`]; named separately because the two roles are separate.
pub const GROUP: &str = domain!();

/// `group/version` of Kix's own records.
pub const API_VERSION: &str = concat!(domain!(), "/v1alpha1");

/// The address of Kix's documentation site, which messages link to.
pub const DOCS_URL: &str = concat!("https://", domain!(), "/docs/");

/// The prefix every Kix key starts with, including the slash.
pub(crate) const PREFIX: &str = concat!(domain!(), "/");

/// Kix's website. Not a Kubernetes key: it appears in SARIF reports and SLSA
/// attestations, which name the tool by URI.
pub const WEBSITE: &str = concat!("https://", domain!());

/// The SLSA builder id used when no external builder is named.
pub const SLSA_BUILDER_ID: &str = concat!("https://", domain!(), "/builder/local");

/// The SLSA build type Kix attests to.
pub const SLSA_BUILD_TYPE: &str = concat!("https://", domain!(), "/build/v1");

/// Schema identifier of the deploy receipt written into an Activation's
/// status. Versioned because a reader six months from now has to know which
/// shape it is holding.
pub const RECEIPT_SCHEMA: &str = concat!(domain!(), "/receipt/v1");

/// Field under an Activation's `status` that carries the deploy receipt.
pub const RECEIPT_FIELD: &str = "receipt";

/// Field under an Activation's `status` that lists the builds whose orphans
/// the deploy that finalized it reported and did not delete. See
/// `cluster::activation::KeptOrphanSource`.
pub const ORPHANS_KEPT_FROM_FIELD: &str = "orphansKeptFrom";

/// Field under an Activation's `status` that holds the build's package index.
/// See `eval::package_index::RecordPackageIndex`.
pub const PACKAGE_INDEX_FIELD: &str = "packageIndex";

/// `activations.<domain>`, the CRD name.
pub const ACTIVATIONS_CRD: &str = concat!("activations.", domain!());

/// `packageinstances.<domain>`, the CRD name.
pub const PACKAGE_INSTANCES_CRD: &str = concat!("packageinstances.", domain!());

/// Annotation the Kix operator writes on the Activation CRD when it starts,
/// listing what it handles, comma-separated. The CLI reads it before it hands
/// the operator a request. See `cluster::activation::OperatorFeatures`.
pub const OPERATOR_FEATURES: &str = concat!(domain!(), "/operator-features");

// --- Stamped by the CLI at load time (eval/stamp.rs) ---

/// The 32-char Nix store hash of the resource's sealed manifest. The identity
/// the whole deploy engine compares on.
pub const IDENTITY_HASH: &str = key!("identity-hash");

/// Name of the package instance that owns the resource.
pub const PACKAGE: &str = key!("package");

/// Namespace of the owning package instance.
pub const PACKAGE_NAMESPACE: &str = key!("package-namespace");

/// `stateful` | `durable` | `ephemeral`, from the package's meta.
pub const LIFECYCLE: &str = key!("lifecycle");

/// Result directory the activation was built from, so rollback and deploy can
/// load its manifests without rebuilding. Records only.
pub const BUILT_VIA: &str = key!("built-via");

// --- Written to live objects after apply (cluster/apply.rs, fieldsv1.rs) ---

/// Comma-separated set of activation identity hashes that reference the
/// object. The authority for pruning.
pub const ACTIVATIONS: &str = key!("activations");

/// Hash of the fields Kix owns on the live object, for drift detection.
pub const APPLIED_HASH: &str = key!("applied-hash");

// --- Records: Activation and PackageInstance ---

/// Name of the activation this one superseded.
pub const PREVIOUS: &str = key!("previous");

/// The version of a withdrawn Kix that wrote this record's deploy or
/// rollback, because `KIX_ALLOW_WITHDRAWN` named it.
pub const WITHDRAWN_KIX: &str = key!("withdrawn-kix");

/// The newer Kix that last deployed the cluster before an older minor of Kix
/// wrote this record's deploy or rollback, because `KIX_ALLOW_DOWNGRADE`
/// named it.
pub const DOWNGRADED_FROM: &str = key!("downgraded-from");

/// RFC 3339 timestamp of the deploy that created the activation.
pub const DEPLOYED_AT: &str = key!("deployed-at");

/// Cluster name. A **label**, so records can be listed per cluster.
pub const CLUSTER_LABEL: &str = key!("cluster");

/// The `cluster.kubernetes.uid` of the build a record was deployed from: the
/// UID of the target cluster's `kube-system` Namespace. A **label**, so a
/// deploy can list the records that carry one and refuse an unbound build
/// on a Kubernetes cluster that has any. Absent on records of unbound builds.
pub const KUBERNETES_UID: &str = key!("kubernetes-uid");

/// `import` on a PackageInstance marks it as a marker for a resource Kix
/// references but does not own.
pub const MODE: &str = key!("mode");

// --- Import markers ---

/// Kind of the imported resource.
pub const IMPORT_KIND: &str = key!("import-kind");

/// `apiVersion` of the imported resource.
pub const IMPORT_API_VERSION: &str = key!("import-apiversion");

/// Name of the imported resource.
pub const IMPORT_NAME: &str = key!("import-name");

/// Comma-separated keys an imported Secret must carry.
pub const IMPORT_SECRET_KEYS: &str = key!("import-secret-keys");

/// Kind a CRD ref marker declares (`scope.mkCRDRef`, `kix.mkImport { crds }`).
/// An import marker that carries it is a CRD ref marker.
pub const CRD_KIND: &str = key!("crd-kind");

/// Default API version a CRD ref marker declares for its kind: the version
/// custom resources built from the ref use unless they set their own. The
/// deploy does not read it; tests stamp it to show that.
#[cfg(any(test, feature = "test-util"))]
pub const CRD_VERSION: &str = key!("crd-version");

/// Comma-separated API versions a CRD ref marker declares as served, its
/// default version among them. The library stamps it on every CRD ref marker,
/// and it is the only list the deploy checks against the live CRD. A deploy
/// refuses a build with a CRD ref marker that lacks it.
pub const CRD_SERVED_VERSIONS: &str = key!("crd-served-versions");

// --- Graph and deploy behaviour ---

/// Comma-separated resource references the deploy DAG orders on.
pub const DEPENDS_ON: &str = key!("depends-on");

/// Readiness rule for a custom resource, as JSON.
pub const READINESS: &str = key!("readiness");

/// `"true"` or `"false"`: whether removing the object can lose data. The
/// library writes it from the kind's `holdsData` declaration, or for a
/// PersistentVolumeClaim, a PersistentVolume, or a StatefulSet with claim
/// templates, from the object's shape. Other objects carry none. Migration
/// pair detection reads it.
pub const HOLDS_DATA: &str = key!("holds-data");

/// Comma-separated field paths the resource cedes to another field manager
/// after creation (`spec.versions`, `webhooks[*].rules`). On a 409 confined
/// to these paths, apply retries without them.
pub const CEDE_FIELDS: &str = key!("cede-fields");

/// Objects the resource expects something else to have created, as
/// comma-separated `apiVersion|Kind|name` entries in the resource's own
/// namespace. Apply waits for each to exist first.
pub const EXPECTS: &str = key!("expects");

/// A Job carrying `rerun: on-change` is deleted and created again rather than
/// patched when its [`RERUN_HASH`] changes. See [`RERUN_ON_CHANGE`].
pub const RERUN: &str = key!("rerun");

/// The only value [`RERUN`] honours.
pub const RERUN_ON_CHANGE: &str = "on-change";

/// The hash of a resource's own manifest, without Kix's annotations and
/// without what it depends on (the library's `out.contentHash`). The library
/// writes it on every resource that carries [`RERUN`], and the deploy engine
/// reruns a Job only when it differs from the value the Job was last
/// deployed with.
pub const RERUN_HASH: &str = key!("rerun-hash");

/// Finalizer the operator holds on records it reconciles.
pub const OPERATOR_GC_FINALIZER: &str = key!("operator-gc");

// --- Secrets ---

/// Store path of the SOPS file a Secret is decrypted from at apply time.
pub const SOPS_SOURCE: &str = key!("sops-source");

/// SHA-256 of the encrypted SOPS file a Secret is decrypted from, in hex.
/// The deploy checks the file against it before decrypting.
pub const SOPS_DIGEST: &str = key!("sops-digest");

/// Hash of a Secret's decrypted values. Builds from Kix 0.9 and earlier carry
/// it. Plans hide it, and a bundle with no [`SOPS_DIGEST`] is checked against
/// it.
pub const CONTENT_HASH: &str = key!("content-hash");

/// Where each key of a Secret gets its value: comma-separated `key=source`
/// pairs, where the source is `inline`, `plain`, `sops`, or `controller`.
pub const SECRET_SOURCES: &str = key!("secret-sources");

/// Comma-separated keys a Secret carries. The deploy takes the keys from the
/// SOPS file instead; tests stamp it to show that.
#[cfg(any(test, feature = "test-util"))]
pub const SECRET_KEYS: &str = key!("secret-keys");

/// Return whether `key` is one of Kix's own annotation or label keys.
///
/// Used where Kix strips its own stamps (`kix export` without `--with-kix-metadata` and the
/// content hash that drift compares).
pub fn is_kix_key(key: &str) -> bool {
    key.starts_with(PREFIX) || crate::legacy_domain::is_legacy_key(key)
}

/// Return whether `key` is under Kix's domain, a subdomain of it
/// (`operator.kix.run/`), or a retired domain. Kix reads such keys from the
/// records it writes, so user-supplied record annotations cannot use them.
pub fn is_kix_domain_key(key: &str) -> bool {
    let prefix = key.split_once('/').map_or("", |(p, _)| p);
    std::iter::once(DOMAIN)
        .chain(crate::legacy_domain::DOMAINS.iter().copied())
        .any(|d| prefix == d || prefix.ends_with(&format!(".{d}")))
}

/// Read a Kix annotation off a manifest.
///
/// `key` is a constant from this module. Pass the manifest, not its
/// annotations map.
pub fn get<'a>(manifest: &'a Value, key: &str) -> Option<&'a str> {
    get_in(manifest, "/metadata/annotations", key)
}

/// Read a Kix label off a manifest, as [`get`] reads an annotation.
pub fn label<'a>(manifest: &'a Value, key: &str) -> Option<&'a str> {
    get_in(manifest, "/metadata/labels", key)
}

fn get_in<'a>(manifest: &'a Value, map: &str, key: &str) -> Option<&'a str> {
    let map = manifest.pointer(map)?.as_object()?;
    map.get(key)
        .and_then(Value::as_str)
        .or_else(|| crate::legacy_domain::fallback(key, |k| map.get(k).and_then(Value::as_str)))
}

/// Read a Kix annotation or label off a `kube` metadata map.
pub fn get_meta<'a>(map: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    map.get(key)
        .map(String::as_str)
        .or_else(|| crate::legacy_domain::fallback(key, |k| map.get(k).map(String::as_str)))
}

/// Does this metadata map carry the key?
pub fn contains_meta(map: &BTreeMap<String, String>, key: &str) -> bool {
    get_meta(map, key).is_some()
}

/// Return the identity hashes a [`DEPENDS_ON`] value lists.
///
/// Each comma-separated entry is a hash, or a hash after a `<relation>:`
/// prefix. The library writes `requires:` and `extra:` today. Every relation
/// is a dependency the deploy orders on, so the prefix is dropped whatever
/// it says.
pub fn depends_on_hashes(value: &str) -> impl Iterator<Item = &str> {
    value
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.rsplit_once(':').map_or(s, |(_, hash)| hash))
}

/// Return the `namespace/instance` key of the package that stamped
/// `manifest`, or `None` when it carries no package stamp.
pub fn package_of(manifest: &Value) -> Option<String> {
    Some(package_key(
        get(manifest, PACKAGE_NAMESPACE)?,
        get(manifest, PACKAGE)?,
    ))
}

/// Return the package key [`package_of`] returns, read off a `kube`
/// annotations map.
pub fn package_of_meta(annotations: &BTreeMap<String, String>) -> Option<String> {
    Some(package_key(
        get_meta(annotations, PACKAGE_NAMESPACE)?,
        get_meta(annotations, PACKAGE)?,
    ))
}

fn package_key(namespace: &str, instance: &str) -> String {
    format!("{namespace}/{instance}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keys_are_built_from_the_one_domain() {
        assert_eq!(GROUP, DOMAIN);
        assert_eq!(API_VERSION, format!("{DOMAIN}/v1alpha1"));
        assert_eq!(PREFIX, format!("{DOMAIN}/"));
        assert_eq!(IDENTITY_HASH, format!("{DOMAIN}/identity-hash"));
        assert_eq!(ACTIVATIONS_CRD, format!("activations.{DOMAIN}"));
        assert_eq!(PACKAGE_INSTANCES_CRD, format!("packageinstances.{DOMAIN}"));
        assert_eq!(WEBSITE, format!("https://{DOMAIN}"));
    }

    #[test]
    fn reads_the_current_domain() {
        let m = json!({"metadata": {"annotations": {IDENTITY_HASH: "abc"}}});
        assert_eq!(get(&m, IDENTITY_HASH), Some("abc"));
        assert_eq!(get(&m, PACKAGE), None);
    }

    #[test]
    fn reads_nothing_from_a_manifest_without_annotations() {
        assert_eq!(get(&json!({"metadata": {}}), IDENTITY_HASH), None);
        assert_eq!(get(&json!({}), IDENTITY_HASH), None);
    }

    #[test]
    fn meta_reads_the_current_domain() {
        let map: BTreeMap<String, String> = [(PACKAGE.to_string(), "vm-agent".to_string())].into();
        assert_eq!(get_meta(&map, PACKAGE), Some("vm-agent"));
        assert!(contains_meta(&map, PACKAGE));
        assert!(!contains_meta(&map, IDENTITY_HASH));
    }

    #[test]
    fn kix_keys_are_recognised_and_foreign_ones_are_not() {
        assert!(is_kix_key(IDENTITY_HASH));
        assert!(!is_kix_key("helm.sh/hook"));
        assert!(!is_kix_key("app.kubernetes.io/name"));
    }

    #[test]
    fn depends_on_drops_any_relation_prefix() {
        let hashes: Vec<_> = depends_on_hashes(" a,requires:b,, extra:c ,later:d").collect();
        assert_eq!(hashes, ["a", "b", "c", "d"]);
    }

    #[test]
    fn package_key_reads_both_stamps() {
        let m = json!({"metadata": {"annotations": {PACKAGE: "web", PACKAGE_NAMESPACE: "app"}}});
        assert_eq!(package_of(&m).as_deref(), Some("app/web"));
        let map: BTreeMap<String, String> = [(PACKAGE.to_string(), "web".to_string())].into();
        assert_eq!(package_of_meta(&map), None);
    }

    /// The invariant this module exists for: a Kix domain is spelled in this
    /// file and in `kix/lib/core/annotations.nix`, nowhere else.
    ///
    /// Only string literals count. Comments and doc comments may name a key
    /// for the reader; they are prose, and a move sweeps them with the docs.
    ///
    /// Walks up from `CARGO_MANIFEST_DIR` (`cli/kix-core`) to the repository root.
    /// Skipped when that tree is not there, so a packaged crate still tests
    /// clean.
    #[test]
    fn no_other_file_spells_a_kix_domain() {
        let Some(root) = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .find(|p| p.join("kix/lib/core/annotations.nix").is_file())
        else {
            return;
        };

        // Every file allowed to spell a domain, and why.
        let allowed: &[&str] = &[
            // This file: the one Rust literal.
            "cli/kix-core/src/manifest/keys.rs",
            // The retired domains, listed so old objects still parse.
            "cli/kix-core/src/legacy_domain/mod.rs",
            // The one Nix literal.
            "kix/lib/core/annotations.nix",
            // Test fixtures and integration tests: literal API objects and
            // literal cluster YAML. These serve as an independent check
            // that catches accidental changes to the constants, so they spell
            // the domain directly.
            "cli/kix/tests/fixtures",
            "cli/kix-core/tests/fixtures",
            "cli/kix-operator/tests",
            // The Python half of the compatibility layer. It declares both
            // domains for the same reason `legacy_domain` does, and it
            // cannot reach either constants file.
            "scripts/parity/normalize.py",
            // Read live objects straight from the API server with jq or
            // Python, so they carry their own fallback to a retired domain
            // and have no constant to import.
            "tools/k9s-plugin/plugins.yaml",
            "tools/lib/kix_model.py",
            "tools/nix-browse/nix-browse.py",
            // The release client names the website kix.run, which Kix
            // downloads releases from. It spells no annotation or label.
            "cli/kix/src/release/",
            // The change records script and module name the schema of the
            // JSON file each release publishes. They spell no annotation or
            // label.
            "scripts/change_records/",
            "cli/kix-core/src/changes/",
            // Names the schema of kix-upgrade.json. It spells no annotation.
            "cli/kix-cli/src/commands/upgrade/state.rs",
        ];

        let domains = ["kix.dev", "kix.run"];
        let mut offenders: Vec<String> = Vec::new();
        // Walk every tree that can carry a Kix domain into executable code or
        // cluster definitions.
        let mut stack: Vec<std::path::PathBuf> = ["kix", "cli", "scripts", "tools", "clusters"]
            .iter()
            .map(|d| root.join(d))
            .filter(|p| p.is_dir())
            .collect();
        while let Some(dir) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let rel = path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .to_string();
                if allowed.iter().any(|a| rel.starts_with(a)) {
                    continue;
                }
                // Skip symlinks such as `result` directories created by `nix build`,
                // whose rendered manifests contain Kix domain strings.
                if entry.file_type().is_ok_and(|t| t.is_symlink()) {
                    continue;
                }
                if path.is_dir() {
                    if entry.file_name() != "target" {
                        stack.push(path);
                    }
                    continue;
                }
                // `hash` marks a language whose line comments start with
                // `#`, `slash` one that uses `//`. Anything else is skipped:
                // prose, binaries, lockfiles.
                let hash_comments = match path.extension().and_then(|e| e.to_str()) {
                    Some("nix" | "py" | "sh" | "yaml" | "yml" | "toml") => true,
                    Some("rs" | "json") => false,
                    _ => continue,
                };
                let Ok(text) = std::fs::read_to_string(&path) else {
                    continue;
                };
                for (n, line) in text.lines().enumerate() {
                    let code = code_part(line, hash_comments);
                    if domains.iter().any(|d| code.contains(d)) {
                        offenders.push(format!("{rel}:{}: {}", n + 1, line.trim()));
                    }
                }
            }
        }

        assert!(
            offenders.is_empty(),
            "a Kix domain is spelled in a string literal outside the two constants \
             files. Use kix_core::manifest::keys (Rust) or core/annotations.nix (Nix):\n{}",
            offenders.join("\n")
        );
    }

    /// Return whether a line comment starts at `c` (`#` in Nix/Python/YAML,
    /// `//` in Rust).
    fn starts_comment(c: char, next: Option<&char>, is_nix: bool) -> bool {
        if is_nix {
            c == '#'
        } else {
            c == '/' && next == Some(&'/')
        }
    }

    #[test]
    fn the_domain_walker_sees_lines_inside_multi_line_strings() {
        assert!(code_part("  group: kix.run", true).contains("kix.run"));
        assert!(code_part("  name: activations.kix.run", false).contains("kix.run"));
        // Comments stay exempt, wherever they start.
        assert!(!code_part("// kix.dev/package is the old name", false).contains("kix.dev"));
        assert!(!code_part("# kix.dev/package is the old name", true).contains("kix.dev"));
        assert!(!code_part("let a = 1; // kix.dev", false).contains("kix.dev"));
        // A comment character inside a string does not end the line.
        assert!(code_part("x = \"# kix.run/a\"", true).contains("kix.run"));
    }

    /// Return the portion of `line` before any unquoted line comment.
    ///
    /// Everything outside a line comment counts as code, so domains inside
    /// multi-line Nix `''` blocks or Rust raw strings are still checked even
    /// when a line has no opening quote of its own.
    fn code_part(line: &str, hash_comments: bool) -> String {
        let chars: Vec<char> = line.chars().collect();
        let mut out = String::new();
        let mut in_string = false;
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if in_string {
                if c == '\\' {
                    out.push(c);
                    if let Some(n) = chars.get(i + 1) {
                        out.push(*n);
                    }
                    i += 2;
                    continue;
                }
                if c == '"' {
                    in_string = false;
                }
                out.push(c);
            } else if c == '"' {
                in_string = true;
                out.push(c);
            } else if starts_comment(c, chars.get(i + 1), hash_comments) {
                break;
            } else {
                out.push(c);
            }
            i += 1;
        }
        out
    }
}
