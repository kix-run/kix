//! Check Ed25519 signatures over the files Kix fetches from kix.run.
//!
//! Two keys sign two kinds of file. The `publish` job signs each release's
//! `SHA256SUMS` with a release key and uploads `SHA256SUMS.sig` beside it.
//! The site build signs the release index with an index key and serves
//! `index.json.sig` beside it. Both signature files have the same shape,
//! and the first line names what was signed:
//!
//! ```text
//! kix-release-signature v1
//! keyid=3f9a1c2e
//! signature=<base64 of the 64-byte Ed25519 signature>
//! ```
//!
//! An index signature starts with `kix-index-signature v1` instead.
//!
//! A file may hold more than one `keyid` and `signature` pair, each
//! signature on the line after its key id. Kix accepts the file when one
//! pair verifies with a key it has. During a key rotation the site signs with
//! both keys, so a Kix that knows only one of them still verifies the file.
//!
//! `keyid` is the first 8 hex digits of the SHA-256 of the raw 32-byte public
//! key, and selects one of the keys built into Kix ([`Signed::keys`]).
//! During a key rotation Kix carries both keys, so it verifies a file signed
//! by either. An index key can only say which releases exist, so a stolen
//! index key can hide or withdraw a release but cannot make one.

use base64::Engine;
use sha2::{Digest, Sha256};

use super::Source;

/// The environment variable that adds a release key and an index key, as 64
/// hex digits, so Kix's own tests can sign their releases and index. Only a build with the
/// `test-release-key` feature reads it ([`test_key`]), and the release
/// binaries are built without it. Even then Kix honours it only for a
/// [`Source::Dir`].
pub const TEST_KEY_VAR: &str = "KIX_RELEASE_TEST_KEY";

/// Return the value of [`TEST_KEY_VAR`] in a build with the
/// `test-release-key` feature.
#[cfg(feature = "test-release-key")]
pub fn test_key() -> Option<String> {
    std::env::var(TEST_KEY_VAR).ok()
}

/// Return `None`: a build without the `test-release-key` feature trusts only
/// the built-in keys.
#[cfg(not(feature = "test-release-key"))]
pub fn test_key() -> Option<String> {
    None
}

/// The release keys built into Kix, as `(keyid, hex of the raw public key)`.
/// Add one line per key in `cli/kix/release-keys/`:
/// `("<keyid>", include_str!("../../release-keys/<keyid>.pub"))`.
const RELEASE_KEYS: &[(&str, &str)] =
    &[("07c2b3e1", include_str!("../../release-keys/07c2b3e1.pub"))];

/// The index keys built into Kix, in the same form. Add one line per key in
/// `cli/kix/index-keys/`.
const INDEX_KEYS: &[(&str, &str)] = &[("297d90c8", include_str!("../../index-keys/297d90c8.pub"))];

/// What a signature file signs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signed {
    /// A release's `SHA256SUMS`, signed with a release key.
    Sums,
    /// The release index, signed with an index key.
    Index,
}

impl Signed {
    /// Return the first line of a signature file of this kind.
    pub fn header(self) -> &'static str {
        match self {
            Signed::Sums => "kix-release-signature v1",
            Signed::Index => "kix-index-signature v1",
        }
    }

    /// Return the name of the signature file, for messages.
    pub fn file(self) -> &'static str {
        match self {
            Signed::Sums => "SHA256SUMS.sig",
            Signed::Index => "index.json.sig",
        }
    }

    fn keys(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Signed::Sums => RELEASE_KEYS,
            Signed::Index => INDEX_KEYS,
        }
    }
}

/// A parsed signature file: one signature per key that signed the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub pairs: Vec<(String, Vec<u8>)>,
}

/// Why a signature does not verify.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum VerifyError {
    #[error("{file} is not a valid Kix signature file: {why}")]
    Malformed { file: &'static str, why: String },
    #[error("it was made with key {0}, which this Kix does not have")]
    UnknownKey(String),
    #[error("the signature does not match the file contents")]
    Mismatch,
}

/// Parse the text of a signature file over a file of kind `signed`.
pub fn parse_signature(text: &str, signed: Signed) -> Result<Signature, VerifyError> {
    let bad = |why: &str| VerifyError::Malformed {
        file: signed.file(),
        why: why.to_string(),
    };
    let header = signed.header();
    let mut lines = text.lines();
    if lines.next().map(str::trim_end) != Some(header) {
        return Err(bad(&format!("the first line is not `{header}`")));
    }
    let mut pairs = Vec::new();
    let mut keyid: Option<String> = None;
    for line in lines {
        match line.trim_end().split_once('=') {
            Some(("keyid", v)) => keyid = Some(v.to_string()),
            Some(("signature", v)) => {
                let id = keyid.take().ok_or_else(|| bad("it has no keyid line"))?;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(v)
                    .map_err(|_| bad("the signature is not base64"))?;
                if bytes.len() != 64 {
                    return Err(bad("the signature is not 64 bytes"));
                }
                pairs.push((id, bytes));
            }
            _ => {}
        }
    }
    if pairs.is_empty() {
        return Err(bad("it has no signature line"));
    }
    Ok(Signature { pairs })
}

/// Return the key id of a raw Ed25519 public key.
pub fn keyid(key: &[u8; 32]) -> String {
    hex(&Sha256::digest(key))[..8].to_string()
}

/// Return the keys Kix trusts to sign files of kind `signed` from `source`:
/// the built-in keys, and `test_key` (the value of [`TEST_KEY_VAR`]) when
/// `source` is a directory.
pub fn trusted_keys(
    signed: Signed,
    source: &Source,
    test_key: Option<&str>,
) -> Vec<(String, [u8; 32])> {
    let mut keys: Vec<(String, [u8; 32])> = signed
        .keys()
        .iter()
        .filter_map(|(id, text)| Some((id.to_string(), parse_key(text)?)))
        .collect();
    if let (Source::Dir(_), Some(text)) = (source, test_key)
        && let Some(key) = parse_key(text)
    {
        keys.push((keyid(&key), key));
    }
    keys
}

/// Parse 64 hex digits into a raw public key.
fn parse_key(text: &str) -> Option<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 {
        return None;
    }
    let mut key = [0u8; 32];
    for (i, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(key)
}

/// Check that `sig` is a signature over `bytes` by one of `keys`.
pub fn verify(
    bytes: &[u8],
    sig: &Signature,
    keys: &[(String, [u8; 32])],
) -> Result<(), VerifyError> {
    let mut known = false;
    for (id, signature) in &sig.pairs {
        let Some((_, key)) = keys.iter().find(|(k, _)| k == id) else {
            continue;
        };
        known = true;
        if ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
            .verify(bytes, signature)
            .is_ok()
        {
            return Ok(());
        }
    }
    if known {
        Err(VerifyError::Mismatch)
    } else {
        Err(VerifyError::UnknownKey(
            sig.pairs
                .iter()
                .map(|(id, _)| id.as_str())
                .collect::<Vec<_>>()
                .join(", "),
        ))
    }
}

/// Return the SHA-256 that `sums` (the text of `SHA256SUMS`) lists for
/// `file`, in lower-case hex.
pub fn sum_for(sums: &str, file: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (hash, name) = line.split_once(char::is_whitespace)?;
        let name = name.trim_start();
        let name = name.strip_prefix('*').unwrap_or(name);
        (name == file && hash.len() == 64 && hash.chars().all(|c| c.is_ascii_hexdigit()))
            .then(|| hash.to_ascii_lowercase())
    })
}

/// Return `bytes` in lower-case hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn key_pair() -> Ed25519KeyPair {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
        Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
    }

    fn public(pair: &Ed25519KeyPair) -> [u8; 32] {
        pair.public_key().as_ref().try_into().unwrap()
    }

    fn signature_file(pair: &Ed25519KeyPair, bytes: &[u8], signed: Signed) -> String {
        let sig = base64::engine::general_purpose::STANDARD.encode(pair.sign(bytes).as_ref());
        format!(
            "{}\nkeyid={}\nsignature={sig}\n",
            signed.header(),
            keyid(&public(pair))
        )
    }

    #[test]
    fn a_signature_file_parses() {
        let pair = key_pair();
        let sig =
            parse_signature(&signature_file(&pair, b"sums", Signed::Sums), Signed::Sums).unwrap();
        assert_eq!(sig.pairs.len(), 1);
        assert_eq!(sig.pairs[0].0, keyid(&public(&pair)));
        assert_eq!(sig.pairs[0].1.len(), 64);

        for (text, why) in [
            ("", "first line"),
            (
                "kix-release-signature v2\nkeyid=a\nsignature=b\n",
                "first line",
            ),
            ("kix-release-signature v1\nsignature=AAAA\n", "no keyid"),
            ("kix-release-signature v1\nkeyid=abcd1234\n", "no signature"),
            (
                "kix-release-signature v1\nkeyid=a\nsignature=!!\n",
                "not base64",
            ),
            (
                "kix-release-signature v1\nkeyid=a\nsignature=AAAA\n",
                "not 64 bytes",
            ),
        ] {
            let err = parse_signature(text, Signed::Sums).unwrap_err().to_string();
            assert!(err.contains(why), "{text:?}: {err}");
        }
    }

    #[test]
    fn a_signature_over_one_kind_does_not_parse_as_the_other() {
        let pair = key_pair();
        let sums_sig = signature_file(&pair, b"bytes", Signed::Sums);
        let index_sig = signature_file(&pair, b"bytes", Signed::Index);
        let err = parse_signature(&sums_sig, Signed::Index).unwrap_err();
        assert!(
            err.to_string().starts_with("index.json.sig is not"),
            "{err}"
        );
        assert!(parse_signature(&index_sig, Signed::Sums).is_err());
        assert!(parse_signature(&index_sig, Signed::Index).is_ok());
    }

    #[test]
    fn a_file_verifies_only_with_the_signing_key() {
        let pair = key_pair();
        let sums = b"abc  kix-x86_64-linux.tar.gz\n";
        let sig =
            parse_signature(&signature_file(&pair, sums, Signed::Sums), Signed::Sums).unwrap();
        let keys = vec![(keyid(&public(&pair)), public(&pair))];
        verify(sums, &sig, &keys).unwrap();

        assert_eq!(verify(b"tampered", &sig, &keys), Err(VerifyError::Mismatch));
        let other = key_pair();
        let wrong = vec![(sig.pairs[0].0.clone(), public(&other))];
        assert_eq!(verify(sums, &sig, &wrong), Err(VerifyError::Mismatch));
        assert_eq!(
            verify(sums, &sig, &[]),
            Err(VerifyError::UnknownKey(sig.pairs[0].0.clone()))
        );
    }

    #[test]
    fn a_file_signed_by_two_keys_verifies_with_either() {
        let old = key_pair();
        let new = key_pair();
        let bytes = b"index";
        let one = signature_file(&old, bytes, Signed::Index);
        let two = signature_file(&new, bytes, Signed::Index);
        let both = format!(
            "{one}{}",
            two.lines().skip(1).collect::<Vec<_>>().join("\n")
        );
        let sig = parse_signature(&both, Signed::Index).unwrap();
        assert_eq!(sig.pairs.len(), 2);
        for pair in [&old, &new] {
            let keys = vec![(keyid(&public(pair)), public(pair))];
            verify(bytes, &sig, &keys).unwrap();
        }
        assert!(matches!(
            verify(bytes, &sig, &[]),
            Err(VerifyError::UnknownKey(ids)) if ids.contains(", ")
        ));
    }

    #[test]
    fn the_test_key_counts_only_for_a_directory() {
        let pair = key_pair();
        let key = hex(&public(&pair));
        let dir = Source::Dir("/tmp/releases".into());
        let site = Source::Https("https://kix.run".into());
        for signed in [Signed::Sums, Signed::Index] {
            let builtin = signed.keys().len();
            let trusted = |source, key| trusted_keys(signed, source, key).len();
            assert_eq!(trusted(&dir, Some(&key)), builtin + 1);
            assert_eq!(
                trusted_keys(signed, &dir, Some(&key)).last().unwrap().0,
                keyid(&public(&pair))
            );
            assert_eq!(trusted(&site, Some(&key)), builtin);
            assert_eq!(trusted(&dir, Some("not hex")), builtin);
            assert_eq!(trusted(&dir, None), builtin);
        }
    }

    #[test]
    fn each_built_in_key_matches_its_keyid() {
        for (id, text) in RELEASE_KEYS.iter().chain(INDEX_KEYS) {
            let key = parse_key(text).unwrap_or_else(|| panic!("key {id} is not 64 hex digits"));
            assert_eq!(keyid(&key), *id, "key {id}");
        }
    }

    #[test]
    fn no_key_signs_both_kinds() {
        for (id, _) in RELEASE_KEYS {
            assert!(
                INDEX_KEYS.iter().all(|(other, _)| other != id),
                "key {id} is both a release key and an index key"
            );
        }
    }

    #[test]
    fn sum_for_finds_the_file() {
        let a = "a".repeat(64);
        let b = "B".repeat(64);
        let sums = format!(
            "{a}  kix-x86_64-linux.tar.gz\n{b} *kix-aarch64-darwin.tar.gz\nshort  kix-aarch64-linux.tar.gz\n"
        );
        assert_eq!(sum_for(&sums, "kix-x86_64-linux.tar.gz"), Some(a));
        assert_eq!(
            sum_for(&sums, "kix-aarch64-darwin.tar.gz"),
            Some("b".repeat(64))
        );
        assert_eq!(sum_for(&sums, "kix-aarch64-linux.tar.gz"), None);
        assert_eq!(sum_for(&sums, "kix-x86_64-linux.tar"), None);
    }
}
