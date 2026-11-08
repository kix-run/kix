//! Check a release's `SHA256SUMS` against its Ed25519 signature.
//!
//! The `publish` job signs the bytes of `SHA256SUMS` and uploads
//! `SHA256SUMS.sig` beside it:
//!
//! ```text
//! kix-release-signature v1
//! keyid=3f9a1c2e
//! signature=<base64 of the 64-byte Ed25519 signature>
//! ```
//!
//! `keyid` is the first 8 hex digits of the SHA-256 of the raw 32-byte public
//! key, and selects one of the keys in [`KEYS`]. During a key rotation Kix
//! carries both keys, so it verifies a release signed by either.

use base64::Engine;
use sha2::{Digest, Sha256};

use super::Source;

/// The environment variable that adds a release key, as 64 hex digits. Kix
/// honours it only for a [`Source::Dir`], so tests can sign their own
/// releases and nothing can add a key for a download from a site. Do not
/// document it for users.
pub const TEST_KEY_VAR: &str = "KIX_RELEASE_TEST_KEY";

/// The release keys built into Kix, as `(keyid, hex of the raw public key)`.
/// Add one line per key in `cli/release-keys/`:
/// `("<keyid>", include_str!("../../../release-keys/<keyid>.pub"))`.
const KEYS: &[(&str, &str)] = &[];

/// The first line of a signature file.
const HEADER: &str = "kix-release-signature v1";

/// A parsed `SHA256SUMS.sig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub keyid: String,
    pub bytes: Vec<u8>,
}

/// Why a signature does not verify.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum VerifyError {
    #[error("SHA256SUMS.sig is not a Kix release signature: {0}")]
    Malformed(String),
    #[error("it was made with key {0}, which this Kix does not have")]
    UnknownKey(String),
    #[error("the signature does not match SHA256SUMS")]
    Mismatch,
}

/// Parse the text of `SHA256SUMS.sig`.
pub fn parse_signature(text: &str) -> Result<Signature, VerifyError> {
    let bad = |why: &str| VerifyError::Malformed(why.to_string());
    let mut lines = text.lines();
    if lines.next().map(str::trim_end) != Some(HEADER) {
        return Err(bad(&format!("the first line is not `{HEADER}`")));
    }
    let mut keyid = None;
    let mut signature = None;
    for line in lines {
        match line.trim_end().split_once('=') {
            Some(("keyid", v)) => keyid = Some(v.to_string()),
            Some(("signature", v)) => signature = Some(v.to_string()),
            _ => {}
        }
    }
    let keyid = keyid.ok_or_else(|| bad("it has no keyid line"))?;
    let signature = signature.ok_or_else(|| bad("it has no signature line"))?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(signature)
        .map_err(|_| bad("the signature is not base64"))?;
    if bytes.len() != 64 {
        return Err(bad("the signature is not 64 bytes"));
    }
    Ok(Signature { keyid, bytes })
}

/// Return the key id of a raw Ed25519 public key.
pub fn keyid(key: &[u8; 32]) -> String {
    hex(&Sha256::digest(key))[..8].to_string()
}

/// Return the keys Kix trusts for releases from `source`: the built-in keys,
/// and `test_key` (the value of [`TEST_KEY_VAR`]) when `source` is a
/// directory.
pub fn trusted_keys(source: &Source, test_key: Option<&str>) -> Vec<(String, [u8; 32])> {
    let mut keys: Vec<(String, [u8; 32])> = KEYS
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

/// Check that `sig` is a signature over `sums` by one of `keys`.
pub fn verify_sums(
    sums: &[u8],
    sig: &Signature,
    keys: &[(String, [u8; 32])],
) -> Result<(), VerifyError> {
    let (_, key) = keys
        .iter()
        .find(|(id, _)| *id == sig.keyid)
        .ok_or_else(|| VerifyError::UnknownKey(sig.keyid.clone()))?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(sums, &sig.bytes)
        .map_err(|_| VerifyError::Mismatch)
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

    fn signature_file(pair: &Ed25519KeyPair, sums: &[u8]) -> String {
        let sig = base64::engine::general_purpose::STANDARD.encode(pair.sign(sums).as_ref());
        format!(
            "{HEADER}\nkeyid={}\nsignature={sig}\n",
            keyid(&public(pair))
        )
    }

    #[test]
    fn a_signature_file_parses() {
        let pair = key_pair();
        let sig = parse_signature(&signature_file(&pair, b"sums")).unwrap();
        assert_eq!(sig.keyid, keyid(&public(&pair)));
        assert_eq!(sig.bytes.len(), 64);

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
            let err = parse_signature(text).unwrap_err().to_string();
            assert!(err.contains(why), "{text:?}: {err}");
        }
    }

    #[test]
    fn sums_verify_only_with_the_signing_key() {
        let pair = key_pair();
        let sums = b"abc  kix-x86_64-linux.tar.gz\n";
        let sig = parse_signature(&signature_file(&pair, sums)).unwrap();
        let keys = vec![(keyid(&public(&pair)), public(&pair))];
        verify_sums(sums, &sig, &keys).unwrap();

        assert_eq!(
            verify_sums(b"tampered", &sig, &keys),
            Err(VerifyError::Mismatch)
        );
        let other = key_pair();
        let wrong = vec![(sig.keyid.clone(), public(&other))];
        assert_eq!(verify_sums(sums, &sig, &wrong), Err(VerifyError::Mismatch));
        assert_eq!(
            verify_sums(sums, &sig, &[]),
            Err(VerifyError::UnknownKey(sig.keyid.clone()))
        );
    }

    #[test]
    fn the_test_key_counts_only_for_a_directory() {
        let pair = key_pair();
        let key = hex(&public(&pair));
        let dir = Source::Dir("/tmp/releases".into());
        let site = Source::Https("https://kix.run".into());
        let builtin = KEYS.len();
        assert_eq!(trusted_keys(&dir, Some(&key)).len(), builtin + 1);
        assert_eq!(
            trusted_keys(&dir, Some(&key)).last().unwrap().0,
            keyid(&public(&pair))
        );
        assert_eq!(trusted_keys(&site, Some(&key)).len(), builtin);
        assert_eq!(trusted_keys(&dir, Some("not hex")).len(), builtin);
        assert_eq!(trusted_keys(&dir, None).len(), builtin);
    }

    #[test]
    fn each_built_in_key_matches_its_keyid() {
        for (id, text) in KEYS {
            let key = parse_key(text).unwrap_or_else(|| panic!("key {id} is not 64 hex digits"));
            assert_eq!(keyid(&key), *id, "key {id}");
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
