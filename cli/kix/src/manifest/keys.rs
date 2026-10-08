//! The Kubernetes domain Kix owns, and every annotation, label and API name
//! built on it.
//!
//! # One literal
//!
//! The domain is spelled exactly once in this crate, in [`domain`]. Every key
//! is built from it with [`key`], so a rename is a one-line change here.
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

/// The prefix every Kix key starts with, including the slash.
pub const PREFIX: &str = concat!(domain!(), "/");

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

/// `activations.<domain>`, the CRD name.
pub const ACTIVATIONS_CRD: &str = concat!("activations.", domain!());

/// `packageinstances.<domain>`, the CRD name.
pub const PACKAGE_INSTANCES_CRD: &str = concat!("packageinstances.", domain!());

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

/// RFC 3339 timestamp of the deploy that created the activation.
pub const DEPLOYED_AT: &str = key!("deployed-at");

/// Cluster name. A **label**, so records can be listed per cluster.
pub const CLUSTER_LABEL: &str = key!("cluster");

/// Root resource of a package instance.
pub const ROOT: &str = key!("root");

/// Resources that depend on the package instance.
pub const INVERSE_DEPS: &str = key!("inverse-deps");

/// Package instances this one requires.
pub const PACKAGE_REQUIRES: &str = key!("package-requires");

/// Resources that run after the package instance is ready.
pub const POST_HOOKS: &str = key!("post-hooks");

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

/// Fully qualified DNS name of an imported Service.
pub const IMPORT_FQDN: &str = key!("import-fqdn");

/// Comma-separated keys an imported Secret must carry.
pub const IMPORT_SECRET_KEYS: &str = key!("import-secret-keys");

/// Kind a CRD ref marker declares (`scope.mkCRDRef`, `kix.mkImport { crds }`).
/// An import marker that carries it is a CRD ref marker.
pub const CRD_KIND: &str = key!("crd-kind");

/// Default API version a CRD ref marker declares for its kind: the version
/// custom resources built from the ref use unless they set their own.
pub const CRD_VERSION: &str = key!("crd-version");

/// Comma-separated API versions a CRD ref marker declares as served,
/// `CRD_VERSION` among them. The library stamps it on every CRD ref marker,
/// and it is the only list the deploy checks against the live CRD. A deploy
/// refuses a build with a CRD ref marker that lacks it.
pub const CRD_SERVED_VERSIONS: &str = key!("crd-served-versions");

/// Scope a CRD ref marker declares for its kind: `Namespaced` or `Cluster`.
pub const CRD_SCOPE: &str = key!("crd-scope");

/// Selector of an imported Service, as JSON.
pub const SERVICE_SELECTOR: &str = key!("service-selector");

/// Ports of an imported Service, as JSON.
pub const SERVICE_PORTS: &str = key!("service-ports");

/// Labels of an imported Service, as JSON.
pub const SERVICE_LABELS: &str = key!("service-labels");

// --- Graph and deploy behaviour ---

/// Comma-separated resource references the deploy DAG orders on.
pub const DEPENDS_ON: &str = key!("depends-on");

/// Readiness rule for a custom resource, as JSON.
pub const READINESS: &str = key!("readiness");

/// Comma-separated field paths the resource cedes to another field manager
/// after creation (`spec.versions`, `webhooks[*].rules`). On a 409 confined
/// to these paths, apply retries without them.
pub const CEDE_FIELDS: &str = key!("cede-fields");

/// Objects the resource expects something else to have created, as
/// comma-separated `apiVersion|Kind|name` entries in the resource's own
/// namespace. Apply waits for each to exist first.
pub const EXPECTS: &str = key!("expects");

/// A Job carrying `rerun: on-change` is deleted and created again rather than
/// patched. See [`RERUN_ON_CHANGE`].
pub const RERUN: &str = key!("rerun");

/// The only value [`RERUN`] honours.
pub const RERUN_ON_CHANGE: &str = "on-change";

/// Finalizer the operator holds on records it reconciles.
pub const OPERATOR_GC_FINALIZER: &str = key!("operator-gc");

// --- Secrets ---

/// Store path of the SOPS file a Secret is decrypted from at apply time.
pub const SOPS_SOURCE: &str = key!("sops-source");

/// Hash of a Secret's decrypted content.
pub const CONTENT_HASH: &str = key!("content-hash");

/// Comma-separated keys a Secret carries.
pub const SECRET_KEYS: &str = key!("secret-keys");

/// Kubernetes Secret type.
pub const SECRET_TYPE: &str = key!("secret-type");

/// Data classification of a Secret.
pub const CLASSIFICATION: &str = key!("classification");

/// Rotation policy of a Secret.
pub const ROTATION_POLICY: &str = key!("rotation-policy");

// --- Derived policy and package claims ---

/// `true` on a resource Kix derived rather than one the author wrote.
pub const DERIVED: &str = key!("derived");

/// Which derivation rule produced a network policy.
pub const POLICY_TYPE: &str = key!("policy-type");

/// `<group>/<Kind>/<name>` of the custom resource whose operator created the
/// pods a Service selects.
pub const OPERAND_OF: &str = key!("operand-of");

/// `true` on a monitor that targets something outside Kix, so selector
/// matching is skipped for it.
pub const MONITORS_EXTERNAL_SERVICE: &str = key!("monitors-external-service");

/// Role a resource plays within its package.
pub const ROLE: &str = key!("role");

/// Name of the database cluster a resource belongs to.
pub const DB_CLUSTER: &str = key!("db-cluster");

/// `true` on an instance Kix instantiated on the author's behalf.
pub const AUTO_INSTANTIATED: &str = key!("auto-instantiated");

/// `true` on an optional instance a dependency activated.
pub const OPTIONAL_ACTIVATED: &str = key!("optional-activated");

/// Is this one of Kix's own annotation or label keys?
///
/// Used where Kix strips its own stamps: `kix export --for=exit` and the
/// content hash that drift compares.
pub fn is_kix_key(key: &str) -> bool {
    key.starts_with(PREFIX) || crate::legacy_domain::is_legacy_key(key)
}

/// Is `key` under Kix's domain, a subdomain of it (`operator.kix.run/`),
/// or a retired domain? Kix reads such keys off the records it writes, so
/// no one else may set them there.
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
    /// The invariant this module exists for: a Kix domain is spelled in this
    /// file and in `kix/lib/core/annotations.nix`, nowhere else.
    ///
    /// Only string literals count. Comments and doc comments may name a key
    /// for the reader; they are prose, and a move sweeps them with the docs.
    ///
    /// Walks up from `CARGO_MANIFEST_DIR` (`cli/kix`) to the repository root.
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
            "cli/kix/src/manifest/keys.rs",
            // The retired domains, listed so old objects still parse.
            "cli/kix/src/legacy_domain/mod.rs",
            // The one Nix literal.
            "kix/lib/core/annotations.nix",
            // Test fixtures and integration tests: literal API objects and
            // literal cluster YAML. These are the independent restatement
            // that catches a constant changed by mistake, so they spell the
            // domain directly and a move updates them explicitly. The
            // checklist is in v2_discussions/archive/137_kix_run_domain_migration.md.
            "cli/kix/tests/fixtures",
            "cli/kix-operator/tests",
            // The Python half of the compatibility layer. It declares both
            // domains for the same reason `legacy_domain` does, and it
            // cannot reach either constants file.
            "scripts/parity/normalize.py",
            // Read live objects straight from the apiserver with jq or
            // Python, so they carry their own fallback to a retired domain
            // and have no constant to import.
            "tools/k9s-plugin/plugins.yaml",
            "tools/lib/kix_model.py",
            "tools/nix-browse/nix-browse.py",
        ];

        let domains = ["kix.dev", "kix.run"];
        let mut offenders: Vec<String> = Vec::new();
        // Every tree that can carry a Kix domain into something that runs.
        // `kix` and `cli` alone left the domain free to appear in scripts,
        // plugins and cluster definitions, which is exactly where this move
        // had to update every occurrence explicitly.
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
                // `nix build` leaves a `result` symlink into the store, and
                // built manifests are full of Kix domains by design. Walking
                // into one turns "somebody built a cluster" into a failing
                // test with a confusing message.
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
             files. Use kix::manifest::keys (Rust) or core/annotations.nix (Nix):\n{}",
            offenders.join("\n")
        );
    }

    /// Does a comment start here? `#` in Nix, `//` in Rust.
    fn starts_comment(c: char, next: Option<&char>, is_nix: bool) -> bool {
        if is_nix {
            c == '#'
        } else {
            c == '/' && next == Some(&'/')
        }
    }

    #[test]
    fn the_domain_walker_sees_lines_inside_multi_line_strings() {
        // The hole that let six spellings through: a line in the middle of
        // a Nix `''` block or a Rust raw string opens no quote of its own,
        // so a scanner looking for quoted spans found nothing on it.
        assert!(code_part("  group: kix.run", true).contains("kix.run"));
        assert!(code_part("  name: activations.kix.run", false).contains("kix.run"));
        // Comments stay exempt, wherever they start.
        assert!(!code_part("// kix.dev/package is the old name", false).contains("kix.dev"));
        assert!(!code_part("# kix.dev/package is the old name", true).contains("kix.dev"));
        assert!(!code_part("let a = 1; // kix.dev", false).contains("kix.dev"));
        // A comment character inside a string does not end the line.
        assert!(code_part("x = \"# kix.run/a\"", true).contains("kix.run"));
    }

    /// The part of one line that is not a comment.
    ///
    /// Everything else on the line counts as code. This is
    /// broader than "inside a string literal". The earlier version of this
    /// walked a line for double-quoted spans and reset that state at every
    /// newline, so a domain anywhere inside a Nix `''` block or a Rust raw
    /// string was invisible to it. It passed with six such spellings in the
    /// tree. Only prose is exempt now, and prose is what a comment is.
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
