//! Decide whether to believe the release index.
//!
//! An index is authentic when its signature verifies against an index key
//! built into Kix and its lifetime is no longer than the site gives one. It
//! is fresh when it has not expired, is not dated in the future, and is not
//! older than the newest index this machine accepted before. Kix keeps that
//! newest index in `<data dir>/release-index.json`. A site that serves an old
//! signed index again, to hide a release or a withdrawal, is then refused
//! once the machine has seen a newer one, and an index nobody re-signed
//! stops counting when it expires. The site signs the index again every day.
//!
//! Kix needs a fresh index to choose a release. A Kix that names one version
//! exactly only reads where the files are, and the signed `SHA256SUMS`
//! protects those, so a stale index only warns there ([`Freshness`]).
//!
//! The kept copy also tells a deploy whether the running Kix was withdrawn
//! without asking kix.run every time ([`withdrawal`]).

use std::path::Path;
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::download::{FetchError, Fetcher};
use super::index::{self, Index, Withdrawn};
use super::verify::{self, Signed, VerifyError};
use super::{InstallError, Source};
use crate::installs;
use crate::version::Version;

/// The file in the data directory that holds the newest index Kix accepted.
pub const KEPT_FILE: &str = "release-index.json";

/// The variable that lets a withdrawn Kix write to a cluster anyway. Its
/// value must be the withdrawn version, so a setting left in a shell does not
/// let the next withdrawn release through as well.
pub const ALLOW_WITHDRAWN_VAR: &str = "KIX_ALLOW_WITHDRAWN";

/// How old the kept index may be before a deploy fetches a new one.
const REFRESH_AFTER: Duration = Duration::from_secs(24 * 60 * 60);

/// The longest lifetime, from `generated` to `expires`, that Kix accepts.
/// The site gives seven days. A longer one would let a stolen index key
/// freeze what Kix sees for longer.
const MAX_LIFETIME: chrono::TimeDelta = chrono::TimeDelta::days(8);

/// How far in the future `generated` may be, for clocks that are wrong. A
/// later date would be kept and then make every real index look older.
const MAX_CLOCK_SKEW: chrono::TimeDelta = chrono::TimeDelta::days(1);

/// Whether Kix needs a fresh index for what it does with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Freshness {
    /// Kix chooses a release from the index, so a stale index is refused.
    Required,
    /// Kix installs a version it was given exactly, so a stale index warns.
    Warn,
}

/// An index that [`fetch`] accepted.
pub struct Fetched {
    pub index: Index,
    /// Why the index is not fresh, when [`Freshness::Warn`] let it through.
    pub stale: Option<Refused>,
}

/// The kept index: the bytes the site served and their signature, so Kix
/// can check the copy again when it reads it.
#[derive(Serialize, Deserialize)]
struct Kept {
    index: String,
    signature: String,
}

/// Why Kix does not believe an index.
#[derive(Debug, thiserror::Error)]
pub enum Refused {
    #[error("{0}")]
    Signature(VerifyError),
    #[error("it cannot be read: {0}")]
    Parse(serde_json::Error),
    #[error("it does not say when it was made and when it expires")]
    Undated,
    #[error("it stays current for longer than the 7 days kix.run gives an index")]
    TooLong,
    #[error(
        "it was made at {0}, which is in the future. Check this machine's clock, or report this at https://github.com/kix-run/kix/issues"
    )]
    Future(DateTime<Utc>),
    #[error(
        "it expired at {0}. If this machine's clock is right, the site has not signed a new index. Report this at https://github.com/kix-run/kix/issues"
    )]
    Expired(DateTime<Utc>),
    #[error(
        "it was made at {served}, and this machine already accepted an index made at {kept}. Someone may be serving an old index to hide a release. Report this at https://github.com/kix-run/kix/issues"
    )]
    Older {
        served: DateTime<Utc>,
        kept: DateTime<Utc>,
    },
}

/// Check the index `bytes` against its signature `sig` and the keys Kix
/// trusts, and that it has a lifetime Kix accepts.
fn authentic(bytes: &[u8], sig: &[u8], keys: &[(String, [u8; 32])]) -> Result<Index, Refused> {
    let signature = verify::parse_signature(&String::from_utf8_lossy(sig), Signed::Index)
        .map_err(Refused::Signature)?;
    verify::verify(bytes, &signature, keys).map_err(Refused::Signature)?;
    let index = Index::parse(bytes).map_err(Refused::Parse)?;
    let (Some(generated), Some(expires)) = (index.generated, index.expires) else {
        return Err(Refused::Undated);
    };
    if expires - generated > MAX_LIFETIME {
        return Err(Refused::TooLong);
    }
    Ok(index)
}

/// Check that an authentic `index` is current at `now` and not older than
/// `kept`, the index this machine accepted last.
fn fresh(index: &Index, kept: Option<&Index>, now: DateTime<Utc>) -> Result<(), Refused> {
    let (Some(generated), Some(expires)) = (index.generated, index.expires) else {
        return Err(Refused::Undated);
    };
    if generated > now + MAX_CLOCK_SKEW {
        return Err(Refused::Future(generated));
    }
    if expires <= now {
        return Err(Refused::Expired(expires));
    }
    if let Some(kept) = kept.and_then(|k| k.generated)
        && generated < kept
    {
        return Err(Refused::Older {
            served: generated,
            kept,
        });
    }
    Ok(())
}

/// Fetch the index from `fetcher`'s source and check it. Keep a fresh index
/// as the newest one this machine accepted. A stale one is refused, unless
/// `freshness` is [`Freshness::Warn`].
pub(super) fn fetch(
    fetcher: &mut Fetcher,
    unreachable: &dyn Fn(String) -> InstallError,
    freshness: Freshness,
) -> Result<Fetched, InstallError> {
    let source = fetcher.source().clone();
    let site = source.to_string();
    let keys = verify::trusted_keys(Signed::Index, &source, verify::test_key().as_deref());
    let bytes = fetcher
        .get(index::PATH)
        .map_err(|e| e.into_install_error(unreachable))?;
    let sig = match fetcher.get(index::SIGNATURE_PATH) {
        Ok(sig) => sig,
        Err(FetchError::NotFound(_)) => return Err(InstallError::UnsignedIndex { site }),
        Err(e) => return Err(e.into_install_error(unreachable)),
    };
    let untrusted = |reason| InstallError::UntrustedIndex {
        site: site.clone(),
        reason,
    };
    let index = authentic(&bytes, &sig, &keys).map_err(untrusted)?;
    let kept_path = installs::data_dir().map(|dir| dir.join(KEPT_FILE));
    let kept = kept_path.as_deref().and_then(|p| read_kept(p, &keys));
    match fresh(&index, kept.as_ref(), Utc::now()) {
        Ok(()) => {
            if let Some(path) = &kept_path
                && let Err(e) = keep(path, &bytes, &sig, index.generated)
            {
                tracing::warn!(path = %path.display(), error = %e, "could not keep the release index");
            }
            Ok(Fetched { index, stale: None })
        }
        Err(reason) if freshness == Freshness::Warn => Ok(Fetched {
            index,
            stale: Some(reason),
        }),
        Err(reason) => Err(untrusted(reason)),
    }
}

/// Return the kept index at `path` when its signature still verifies against
/// `keys`. Expiry does not matter here: the kept index only ever moves
/// forward, and an expired one still lists every withdrawal it knew.
fn read_kept(path: &Path, keys: &[(String, [u8; 32])]) -> Option<Index> {
    let text = std::fs::read_to_string(path).ok()?;
    let kept: Kept = serde_json::from_str(&text).ok()?;
    let signature = verify::parse_signature(&kept.signature, Signed::Index).ok()?;
    verify::verify(kept.index.as_bytes(), &signature, keys).ok()?;
    Index::parse(kept.index.as_bytes()).ok()
}

/// Write the index and its signature to `path`, replacing the file in one
/// step so a reader never sees half of it. Leave a kept index made after
/// `generated` alone, which another Kix may have written since this one read
/// it.
fn keep(
    path: &Path,
    bytes: &[u8],
    sig: &[u8],
    generated: Option<DateTime<Utc>>,
) -> std::io::Result<()> {
    let newer_kept = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Kept>(&text).ok())
        .and_then(|kept| Index::parse(kept.index.as_bytes()).ok()?.generated);
    if newer_kept.is_some_and(|kept| Some(kept) > generated) {
        return Ok(());
    }
    let kept = Kept {
        index: String::from_utf8(bytes.to_vec())
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?,
        signature: String::from_utf8_lossy(sig).into_owned(),
    };
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{KEPT_FILE}.tmp-{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&kept)?)?;
    std::fs::rename(&tmp, path)
}

/// Return the withdrawal of `version` that the release index lists, or
/// `None` when it lists none or Kix has no index to read.
///
/// With `refresh`, Kix fetches the index first when the kept copy is more
/// than a day old, giving up after a few seconds. Without it, Kix reads only
/// the kept copy and makes no network request. A failed fetch falls back to
/// the kept copy, so a machine that cannot reach the site still deploys.
pub fn withdrawal(version: &Version, refresh: bool) -> Option<Withdrawn> {
    let source = Source::from_env();
    let keys = verify::trusted_keys(Signed::Index, &source, verify::test_key().as_deref());
    let kept_path = installs::data_dir().map(|dir| dir.join(KEPT_FILE));
    let age = kept_path
        .as_deref()
        .and_then(|p| std::fs::metadata(p).ok())
        .and_then(|m| m.modified().ok())
        .and_then(|t| SystemTime::now().duration_since(t).ok());
    if refresh && age.is_none_or(|age| age > REFRESH_AFTER) {
        let mut fetcher = Fetcher::quick(source.clone());
        let unreachable = |message: String| InstallError::Download {
            url: format!("{source}{}", index::PATH),
            message,
        };
        match fetch(&mut fetcher, &unreachable, Freshness::Required) {
            Ok(fetched) => return fetched.index.withdrawal(version).cloned(),
            Err(e @ InstallError::Download { .. }) => {
                tracing::debug!(error = %e, "could not fetch the release index");
            }
            Err(e) => {
                tracing::warn!(error = %e, "could not check whether this Kix was withdrawn");
            }
        }
    }
    let kept = read_kept(kept_path.as_deref()?, &keys)?;
    kept.withdrawal(version).cloned()
}

/// Whether a Kix may write to a cluster, given its withdrawal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The release index lists no withdrawal of this Kix.
    Current,
    /// This Kix was withdrawn, and [`ALLOW_WITHDRAWN_VAR`] names it.
    Allowed(Withdrawn),
    /// This Kix was withdrawn.
    Refused(Withdrawn),
}

/// Decide whether a Kix with `withdrawn` may write to a cluster, when
/// [`ALLOW_WITHDRAWN_VAR`] is `allow`.
pub fn judge(withdrawn: Option<Withdrawn>, allow: Option<&str>) -> Verdict {
    match withdrawn {
        None => Verdict::Current,
        Some(w) if allow.map(str::trim) == Some(w.version.release().as_str()) => {
            Verdict::Allowed(w)
        }
        Some(w) => Verdict::Refused(w),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    struct Signer(Ed25519KeyPair);

    impl Signer {
        fn new() -> Self {
            let rng = ring::rand::SystemRandom::new();
            let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
            Signer(Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap())
        }

        fn keys(&self) -> Vec<(String, [u8; 32])> {
            let key: [u8; 32] = self.0.public_key().as_ref().try_into().unwrap();
            vec![(verify::keyid(&key), key)]
        }

        fn sign(&self, bytes: &[u8], signed: Signed) -> Vec<u8> {
            let sig = base64::engine::general_purpose::STANDARD.encode(self.0.sign(bytes).as_ref());
            format!(
                "{}\nkeyid={}\nsignature={sig}\n",
                signed.header(),
                self.keys()[0].0
            )
            .into_bytes()
        }
    }

    fn time(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text).unwrap().into()
    }

    fn index(generated: &str, expires: &str) -> Vec<u8> {
        serde_json::json!({
            "schema": "kix.run/releases/v1",
            "generated": generated,
            "expires": expires,
            "latest": "0.10.1",
            "releases": [],
            "withdrawn": [{ "version": "0.10.0", "reason": "it breaks", "use": "0.10.1" }],
        })
        .to_string()
        .into_bytes()
    }

    const NOW: &str = "2026-11-20T12:00:00Z";

    fn accept(
        bytes: &[u8],
        sig: &[u8],
        keys: &[(String, [u8; 32])],
        kept: Option<&Index>,
        now: DateTime<Utc>,
    ) -> Result<Index, Refused> {
        let index = authentic(bytes, sig, keys)?;
        fresh(&index, kept, now)?;
        Ok(index)
    }

    #[test]
    fn an_index_from_the_future_or_with_a_long_life_is_refused() {
        let signer = Signer::new();
        let future = index("2026-11-22T00:00:00Z", "2026-11-29T00:00:00Z");
        let sig = signer.sign(&future, Signed::Index);
        let err = accept(&future, &sig, &signer.keys(), None, time(NOW)).unwrap_err();
        assert!(matches!(err, Refused::Future(_)), "{err}");
        // A clock a few hours behind still accepts a fresh index.
        let soon = index("2026-11-20T18:00:00Z", "2026-11-27T18:00:00Z");
        let sig = signer.sign(&soon, Signed::Index);
        accept(&soon, &sig, &signer.keys(), None, time(NOW)).unwrap();

        let long = index("2026-11-19T00:00:00Z", "9999-01-01T00:00:00Z");
        let sig = signer.sign(&long, Signed::Index);
        let err = authentic(&long, &sig, &signer.keys()).unwrap_err();
        assert!(matches!(err, Refused::TooLong), "{err}");
    }

    #[test]
    fn a_slower_writer_does_not_move_the_kept_index_back() {
        let signer = Signer::new();
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(KEPT_FILE);
        let newer = index("2026-11-19T00:00:00Z", "2026-11-26T00:00:00Z");
        let older = index("2026-11-18T00:00:00Z", "2026-11-25T00:00:00Z");
        let generated = |bytes: &[u8]| Index::parse(bytes).unwrap().generated;
        keep(
            &path,
            &newer,
            &signer.sign(&newer, Signed::Index),
            generated(&newer),
        )
        .unwrap();
        keep(
            &path,
            &older,
            &signer.sign(&older, Signed::Index),
            generated(&older),
        )
        .unwrap();
        let kept = read_kept(&path, &signer.keys()).unwrap();
        assert_eq!(kept.generated, generated(&newer));
    }

    #[test]
    fn a_signed_current_index_is_accepted() {
        let signer = Signer::new();
        let bytes = index("2026-11-19T00:00:00Z", "2026-11-26T00:00:00Z");
        let sig = signer.sign(&bytes, Signed::Index);
        let index = accept(&bytes, &sig, &signer.keys(), None, time(NOW)).unwrap();
        assert_eq!(index.withdrawn.len(), 1);
        assert_eq!(
            index.withdrawal(&"0.10.0".parse().unwrap()).unwrap().reason,
            "it breaks"
        );
    }

    #[test]
    fn an_index_signed_by_another_key_or_as_sums_is_refused() {
        let signer = Signer::new();
        let other = Signer::new();
        let bytes = index("2026-11-19T00:00:00Z", "2026-11-26T00:00:00Z");
        let refused = |sig: &[u8]| accept(&bytes, sig, &signer.keys(), None, time(NOW));
        assert!(matches!(
            refused(&other.sign(&bytes, Signed::Index)),
            Err(Refused::Signature(VerifyError::UnknownKey(_)))
        ));
        assert!(matches!(
            refused(&signer.sign(&bytes, Signed::Sums)),
            Err(Refused::Signature(VerifyError::Malformed { .. }))
        ));
        assert!(matches!(
            refused(&signer.sign(b"other bytes", Signed::Index)),
            Err(Refused::Signature(VerifyError::Mismatch))
        ));
    }

    #[test]
    fn an_expired_or_undated_index_is_refused() {
        let signer = Signer::new();
        let expired = index("2026-11-10T00:00:00Z", "2026-11-17T00:00:00Z");
        let sig = signer.sign(&expired, Signed::Index);
        let err = accept(&expired, &sig, &signer.keys(), None, time(NOW)).unwrap_err();
        assert!(matches!(err, Refused::Expired(_)), "{err}");

        let undated = br#"{"schema": "kix.run/releases/v1", "latest": null, "releases": []}"#;
        let sig = signer.sign(undated, Signed::Index);
        let err = accept(undated, &sig, &signer.keys(), None, time(NOW)).unwrap_err();
        assert!(matches!(err, Refused::Undated), "{err}");
    }

    #[test]
    fn an_index_older_than_the_kept_one_is_refused() {
        let signer = Signer::new();
        let keys = signer.keys();
        let newer = index("2026-11-19T00:00:00Z", "2026-11-26T00:00:00Z");
        let older = index("2026-11-18T00:00:00Z", "2026-11-25T00:00:00Z");
        let kept = Index::parse(&newer).unwrap();
        let err = accept(
            &older,
            &signer.sign(&older, Signed::Index),
            &keys,
            Some(&kept),
            time(NOW),
        )
        .unwrap_err();
        assert!(matches!(err, Refused::Older { .. }), "{err}");
        // The same index again is fine.
        accept(
            &newer,
            &signer.sign(&newer, Signed::Index),
            &keys,
            Some(&kept),
            time(NOW),
        )
        .unwrap();
    }

    #[test]
    fn only_the_withdrawn_version_named_lets_a_write_through() {
        let w = Withdrawn {
            version: "0.10.0".parse().unwrap(),
            reason: "it breaks".into(),
            use_instead: Some("0.10.1".parse().unwrap()),
            release: None,
        };
        assert_eq!(judge(None, Some("0.10.0")), Verdict::Current);
        assert_eq!(judge(Some(w.clone()), None), Verdict::Refused(w.clone()));
        assert_eq!(
            judge(Some(w.clone()), Some("1")),
            Verdict::Refused(w.clone())
        );
        assert_eq!(
            judge(Some(w.clone()), Some("0.9.0")),
            Verdict::Refused(w.clone())
        );
        assert_eq!(judge(Some(w.clone()), Some("0.10.0")), Verdict::Allowed(w));
    }

    #[test]
    fn the_kept_index_counts_only_while_its_signature_verifies() {
        let signer = Signer::new();
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("nested").join(KEPT_FILE);
        let bytes = index("2026-11-19T00:00:00Z", "2026-11-26T00:00:00Z");
        let generated = Index::parse(&bytes).unwrap().generated;
        keep(
            &path,
            &bytes,
            &signer.sign(&bytes, Signed::Index),
            generated,
        )
        .unwrap();
        assert!(read_kept(&path, &signer.keys()).is_some());
        assert!(read_kept(&path, &Signer::new().keys()).is_none());

        keep(&path, b"{}", &signer.sign(&bytes, Signed::Index), generated).unwrap();
        assert!(read_kept(&path, &signer.keys()).is_none());
        assert!(read_kept(&tmp.path().join("missing"), &signer.keys()).is_none());
    }
}
