//! Nix store paths computed from content.
//!
//! The files a cluster build is made of are content-addressed: manifests and
//! `kix-packages.json` come from `builtins.toFile` (a text path) and SOPS
//! sources from `builtins.path` (a source path, hashed over its NAR
//! serialisation). Their store path is a function of their bytes, their
//! references and their name, so a path can be checked against a file
//! without a Nix store. A reader of a build that holds no Nix store relies
//! on this to refuse a file whose path was not made from it.
//!
//! The rules follow Nix's `makeStorePath`, `makeTextPath` and
//! `makeFixedOutputPath` for recursive SHA-256.

use sha2::{Digest, Sha256};

/// The store directory every path in a build lives under.
pub const STORE_DIR: &str = "/nix/store";

/// Nix's base32 alphabet: no `e`, `o`, `u` or `t`.
const BASE32: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

/// How a content-addressed store path was made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// `builtins.toFile`: the hash covers the file's bytes.
    Text,
    /// `builtins.path` of a single regular file: the hash covers the file's
    /// NAR serialisation, which records whether the file is executable.
    /// [`path_for`] gives the path of a file that is not.
    Source,
}

/// The longest store name Nix accepts (`StorePath::MaxPathLen`).
pub const MAX_NAME_BYTES: usize = 211;

/// The store path a file gets under `method`, given its bytes, the store
/// paths it references, and its name (the part after `<hash>-`).
///
/// ```
/// use kix::eval::store_path::{Method, path_for};
/// let p = path_for(Method::Text, b"hello", &[], "greeting");
/// assert!(p.starts_with("/nix/store/") && p.ends_with("-greeting"));
/// ```
pub fn path_for(method: Method, bytes: &[u8], references: &[String], name: &str) -> String {
    path_with(method, false, bytes, references, name)
}

/// The method that makes `path` from `bytes`, `references` and the path's
/// own name, or `None` if neither does. A source path may be of an
/// executable file or not.
pub fn method_of<S: AsRef<str>>(path: &str, bytes: &[u8], references: &[S]) -> Option<Method> {
    let name = name_of(path)?;
    [
        (Method::Text, false),
        (Method::Source, false),
        (Method::Source, true),
    ]
    .into_iter()
    .find(|(m, executable)| path_with(*m, *executable, bytes, references, name) == path)
    .map(|(m, _)| m)
}

/// Nix's type string, `<kind>:<reference>:<reference>...`, can be as long
/// as the references put together, so it goes into the hash piece by piece.
/// `executable` applies to [`Method::Source`] only.
fn path_with<S: AsRef<str>>(
    method: Method,
    executable: bool,
    bytes: &[u8],
    references: &[S],
    name: &str,
) -> String {
    let (kind, digest) = match method {
        Method::Text => ("text", Sha256::digest(bytes)),
        Method::Source => ("source", Sha256::digest(nar_of_file(bytes, executable))),
    };
    let mut refs: Vec<&str> = references.iter().map(AsRef::as_ref).collect();
    refs.sort_unstable();
    refs.dedup();
    let mut fingerprint = Sha256::new();
    fingerprint.update(kind);
    for r in refs {
        fingerprint.update(":");
        fingerprint.update(r);
    }
    fingerprint.update(format!(":sha256:{}:{STORE_DIR}:{name}", hex(&digest)));
    make_store_path(&fingerprint.finalize(), name)
}

/// The name part of a store path: what follows `/nix/store/<hash>-`. `None`
/// unless the hash is Nix base32 and the name is one Nix accepts.
pub fn name_of(path: &str) -> Option<&str> {
    let rest = path.strip_prefix(STORE_DIR)?.strip_prefix('/')?;
    let (hash, name) = rest.split_at_checked(32)?;
    if !hash.bytes().all(|b| BASE32.contains(&b)) {
        return None;
    }
    let name = name.strip_prefix('-')?;
    valid_name(name).then_some(name)
}

/// Nix's `checkName`: 1 to [`MAX_NAME_BYTES`] characters from
/// `[A-Za-z0-9+-._?=]`, and not `.` or `..`, alone or before a `-`.
fn valid_name(name: &str) -> bool {
    let allowed = |b: u8| b.is_ascii_alphanumeric() || b"+-._?=".contains(&b);
    !name.is_empty()
        && name.len() <= MAX_NAME_BYTES
        && name.bytes().all(allowed)
        && !matches!(name, "." | "..")
        && !name.starts_with(".-")
        && !name.starts_with("..-")
}

/// The store path whose fingerprint (`<type>:sha256:<hex>:<store>:<name>`)
/// hashes to `full`.
fn make_store_path(full: &[u8], name: &str) -> String {
    let mut short = [0u8; 20];
    for (i, b) in full.iter().enumerate() {
        short[i % 20] ^= b;
    }
    format!("{STORE_DIR}/{}-{name}", base32(&short))
}

/// Nix's base32: little-endian, five bits at a time, last character first.
fn base32(bytes: &[u8]) -> String {
    let len = (bytes.len() * 8 - 1) / 5 + 1;
    (0..len)
        .rev()
        .map(|n| {
            let b = n * 5;
            let (i, j) = (b / 8, b % 8);
            let low = bytes[i] >> j;
            let high = bytes
                .get(i + 1)
                .map_or(0, |next| next.checked_shl(8 - j as u32).unwrap_or(0));
            BASE32[((low | high) & 0x1f) as usize] as char
        })
        .collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The NAR serialisation of one regular file.
fn nar_of_file(contents: &[u8], executable: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(contents.len() + 160);
    for s in [b"nix-archive-1".as_slice(), b"(", b"type", b"regular"] {
        nar_str(&mut out, s);
    }
    if executable {
        nar_str(&mut out, b"executable");
        nar_str(&mut out, b"");
    }
    nar_str(&mut out, b"contents");
    nar_str(&mut out, contents);
    nar_str(&mut out, b")");
    out
}

fn nar_str(out: &mut Vec<u8>, s: &[u8]) {
    out.extend_from_slice(&(s.len() as u64).to_le_bytes());
    out.extend_from_slice(s);
    out.resize(out.len().next_multiple_of(8), 0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base32_matches_nix_for_a_known_hash() {
        // `nix hash convert --to nix32 --hash-algo sha256` of sha256("").
        let empty = Sha256::digest(b"");
        assert_eq!(
            base32(&empty),
            "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"
        );
    }

    #[test]
    fn a_name_needs_a_valid_hash_and_no_slash() {
        let hash = "0h5dy43cxa771fiz9dsx14c0vf32sn67";
        assert_eq!(name_of(&format!("/nix/store/{hash}-x")), Some("x"));
        assert_eq!(name_of(&format!("/nix/store/{hash}-x/y")), None);
        assert_eq!(
            name_of("/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn6e-x"),
            None
        );
        assert_eq!(name_of(&format!("/tmp/{hash}-x")), None);
        assert_eq!(name_of(&format!("/nix/store/{hash}-")), None);
    }

    /// Nix's `checkName`: at most 211 characters from `[A-Za-z0-9+-._?=]`,
    /// and not `.` or `..`, alone or before a `-`.
    #[test]
    fn a_name_follows_nix_rules() {
        let path = |name: &str| format!("/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-{name}");
        let longest = "a".repeat(211);
        for good in [
            "k8s-ConfigMap-x",
            "db.sops.yaml",
            "a+b=c?d_e",
            ".a",
            "..a",
            &longest,
        ] {
            assert_eq!(name_of(&path(good)), Some(good), "{good}");
        }
        let too_long = "a".repeat(212);
        for bad in [
            "a b",
            "k8s-\u{1b}[2J",
            "caf\u{e9}",
            "a:b",
            ".",
            "..",
            ".-a",
            "..-a",
            &too_long,
        ] {
            assert_eq!(name_of(&path(bad)), None, "{bad:?}");
        }
    }

    #[test]
    fn changing_bytes_references_or_name_changes_the_path() {
        let base = path_for(Method::Text, b"a", &[], "n");
        assert_ne!(base, path_for(Method::Text, b"b", &[], "n"));
        assert_ne!(
            base,
            path_for(Method::Text, b"a", &["/nix/store/x".into()], "n")
        );
        assert_ne!(base, path_for(Method::Text, b"a", &[], "m"));
        assert_ne!(base, path_for(Method::Source, b"a", &[], "n"));
    }

    /// Files and references captured from a real `kix-enterprise-test`
    /// build on stage1: the Activation record, `kix-packages.json`, and three
    /// manifests. Each must recompute to the path Nix gave it.
    #[test]
    fn real_build_paths_recompute_to_themselves() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/store_paths/kix-enterprise-test.json"
        ))
        .unwrap();
        for file in fixture.as_array().unwrap() {
            let path = file["path"].as_str().unwrap();
            let text = file["text"].as_str().unwrap();
            let refs: Vec<String> = serde_json::from_value(file["references"].clone()).unwrap();
            assert_eq!(
                method_of(path, text.as_bytes(), &refs),
                Some(Method::Text),
                "{path} did not recompute"
            );
            let mut changed = text.as_bytes().to_vec();
            changed[0] ^= 1;
            assert_eq!(method_of(path, &changed, &refs), None, "{path}");
        }
    }

    /// The path `builtins.path { path = ./db.sops.yaml; name = "db.sops.yaml"; }`
    /// gave this file, as SOPS sources are added.
    #[test]
    fn a_builtins_path_file_recomputes_as_a_source_path() {
        let bytes = b"password: ENC[AES256_GCM,data:abc]\nsops:\n  age: []\n";
        let path = "/nix/store/yxyad967bhmxvm5120mrjnrrr7ak087w-db.sops.yaml";
        assert_eq!(method_of::<String>(path, bytes, &[]), Some(Method::Source));
    }

    /// The same file with mode 0755, as a checkout from a filesystem with
    /// no mode bits gives it. Nix keeps the bit in the NAR it hashes.
    #[test]
    fn an_executable_builtins_path_file_recomputes_as_a_source_path() {
        let bytes = b"password: ENC[AES256_GCM,data:abc]\nsops:\n  age: []\n";
        let path = "/nix/store/mksphybbsiaag8ayhgj6bqq79f7p5cws-db.sops.yaml";
        assert_eq!(method_of::<String>(path, bytes, &[]), Some(Method::Source));
    }

    #[test]
    fn reference_order_does_not_matter() {
        let a = "/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-a".to_string();
        let b = "/nix/store/jicid73ajxhrjk89v9y0lb01wbf9bh2m-b".to_string();
        assert_eq!(
            path_for(Method::Text, b"x", &[a.clone(), b.clone()], "n"),
            path_for(Method::Text, b"x", &[b, a], "n")
        );
    }
}
