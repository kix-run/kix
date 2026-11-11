//! Fetch, verify, and install a released version of Kix.
//!
//! Everything comes from kix.run. The site serves the release index at
//! `/releases/index.json` ([`index`]), each release's `SHA256SUMS` and its
//! Ed25519 signature beside it, and the release archives under `/download/`,
//! which the site redirects to wherever they are stored. Kix trusts none of
//! those locations. It checks the signature of `SHA256SUMS` against a key
//! compiled into Kix ([`verify`]) and the archive against `SHA256SUMS`
//! before it unpacks anything ([`download`]). [`changes`] fetches a
//! release's change records the same way.
//!
//! An install unpacks into a `tmp-*` directory beside the installed versions
//! and renames the result into place, so `<data dir>/<version>` is either a
//! whole release or absent ([`crate::installs`]).

pub mod download;
pub mod index;
pub mod verify;

use std::path::{Path, PathBuf};

use sha2::Digest;

use crate::installs::{self, Install};
use crate::version::policy::Requirement;
use crate::version::{self, Version};

/// The environment variable that points Kix at another release source: a
/// mirror of kix.run, or a directory in Kix's own tests. Kix checks a
/// mirror's files against the keys built into Kix, as it does kix.run's.
pub const SOURCE_VAR: &str = "KIX_RELEASE_SOURCE";

/// The site Kix fetches releases from.
pub const DEFAULT_SOURCE: &str = "https://kix.run";

/// The page that explains how to install Kix.
pub const INSTALL_DOCS: &str =
    "https://kix.run/docs/how-to/start-and-inspect/install-and-run-the-kix-cli/";

/// Where Kix fetches releases from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// A site with the layout of kix.run, such as `https://kix.run`.
    Https(String),
    /// A directory with the same layout. Only tests use one.
    Dir(PathBuf),
}

impl Source {
    /// Return the source [`SOURCE_VAR`] names: a directory when it is an
    /// absolute path, otherwise a site. Without it, return kix.run.
    pub fn from_env() -> Self {
        match std::env::var_os(SOURCE_VAR).filter(|v| !v.is_empty()) {
            Some(v) if Path::new(&v).is_absolute() => Source::Dir(PathBuf::from(v)),
            Some(v) => Source::Https(v.to_string_lossy().trim_end_matches('/').to_string()),
            None => Source::Https(DEFAULT_SOURCE.to_string()),
        }
    }
}

impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Source::Https(url) => f.write_str(url),
            Source::Dir(dir) => write!(f, "{}", dir.display()),
        }
    }
}

/// Why Kix did not install a release.
#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error(
        "Kix has no release for {os} {arch}. Supported: x86_64-linux, aarch64-linux, aarch64-darwin"
    )]
    UnsupportedSystem { os: String, arch: String },

    #[error(
        "Kix {} has no release signing key built in, so it cannot verify downloads. Install Kix from {INSTALL_DOCS}",
        version::running().release()
    )]
    NoKeys,

    #[error(
        "could not reach {site}: {message}. Set KIX_AUTO_INSTALL=0 to stop Kix from installing versions, and install Kix {req} with the install script"
    )]
    Unreachable {
        site: String,
        req: String,
        message: String,
    },

    #[error("could not download {url}: {message}")]
    Download { url: String, message: String },

    #[error("the release index from {site} cannot be read: {message}")]
    BadIndex { site: String, message: String },

    #[error("{}", no_release_message(.req, .system, .latest.as_deref(), .prerelease.as_deref()))]
    NoRelease {
        req: String,
        system: String,
        latest: Option<String>,
        /// The newest prerelease of the minor asked for, which a minor
        /// requirement never installs.
        prerelease: Option<String>,
    },

    #[error("Kix {version} has no release signature, so Kix cannot verify it")]
    NoSignature { version: String },

    #[error(
        "the release signature for Kix {version} does not verify against any key built into Kix {}. Kix did not install it. Report this at https://kix.run",
        version::running().release()
    )]
    BadSignature {
        version: String,
        #[source]
        reason: verify::VerifyError,
    },

    #[error("SHA256SUMS of Kix {version} lists no {file}")]
    NotInSums { version: String, file: String },

    #[error("downloaded {file} does not match SHA256SUMS (expected {expected}, got {got})")]
    ShaMismatch {
        file: String,
        expected: String,
        got: String,
    },

    #[error("the release archive of Kix {version} cannot be installed: {reason}")]
    BadArchive { version: String, reason: String },

    #[error("the change records of Kix {version} cannot be read: {message}")]
    BadChanges { version: String, message: String },

    #[error("{}", installs::NO_HOME)]
    NoHome,

    #[error("could not write {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

fn no_release_message(
    req: &str,
    system: &str,
    latest: Option<&str>,
    prerelease: Option<&str>,
) -> String {
    let mut message = match latest {
        Some(latest) => {
            format!("no Kix {req} release exists for {system}. The newest release is {latest}")
        }
        None => format!("no Kix {req} release exists for {system}. kix.run lists no releases yet"),
    };
    if let Some(pre) = prerelease {
        message.push_str(&format!(
            ". Kix {pre} is a prerelease, which Kix installs only when it is named exactly. To install it, run `kix self install {pre}`"
        ));
    }
    message
}

impl InstallError {
    fn io(path: &Path) -> impl FnOnce(std::io::Error) -> Self + '_ {
        move |source| InstallError::Io {
            path: path.to_path_buf(),
            source,
        }
    }
}

/// Return the release system name of this machine, such as `aarch64-darwin`.
pub fn system() -> Result<String, InstallError> {
    system_for(std::env::consts::OS, std::env::consts::ARCH)
}

fn system_for(os: &str, arch: &str) -> Result<String, InstallError> {
    let unsupported = || InstallError::UnsupportedSystem {
        os: os.to_string(),
        arch: arch.to_string(),
    };
    let os_name = match os {
        "linux" => "linux",
        "macos" => "darwin",
        _ => return Err(unsupported()),
    };
    match (arch, os_name) {
        ("x86_64", "linux") | ("aarch64", "linux") | ("aarch64", "darwin") => {
            Ok(format!("{arch}-{os_name}"))
        }
        _ => Err(unsupported()),
    }
}

/// The result of [`install`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installed {
    pub install: Install,
    /// Whether Kix downloaded it, or found it installed already.
    pub downloaded: bool,
}

/// Install the newest release that meets `req` for `system` from `source`,
/// unless that version is installed already. `starting` is called with the
/// version before Kix downloads it.
///
/// The archive is checked against the signed `SHA256SUMS` before it is
/// unpacked, and nothing lands under `<data dir>/<version>` unless every
/// check passed.
pub fn install(
    req: &Requirement,
    system: &str,
    source: &Source,
    starting: &dyn Fn(&Version),
) -> Result<Installed, InstallError> {
    let keys = verify::trusted_keys(source, std::env::var(verify::TEST_KEY_VAR).ok().as_deref());
    if keys.is_empty() {
        return Err(InstallError::NoKeys);
    }
    let data = installs::data_dir().ok_or(InstallError::NoHome)?;
    let mut fetcher = download::Fetcher::new(source.clone());
    let unreachable = |message: String| InstallError::Unreachable {
        site: source.to_string(),
        req: req.to_string(),
        message,
    };
    let index_bytes = fetcher
        .get(index::PATH)
        .map_err(|e| e.into_install_error(&unreachable))?;
    let index = index::Index::parse(&index_bytes).map_err(|message| InstallError::BadIndex {
        site: source.to_string(),
        message,
    })?;
    let release = index
        .newest(req, system)
        .ok_or_else(|| InstallError::NoRelease {
            req: req.to_string(),
            system: system.to_string(),
            latest: index.latest.clone(),
            prerelease: match req {
                Requirement::Minor(..) => index
                    .newest_prerelease(req, system)
                    .map(|r| r.version.release()),
                Requirement::Exact(_) => None,
            },
        })?;
    let v = release.version.release();
    if let Some(existing) = installs::installed()
        .into_iter()
        .find(|i| i.version == release.version)
    {
        return Ok(Installed {
            install: existing,
            downloaded: false,
        });
    }
    starting(&release.version);

    let sums = verified_sums(&mut fetcher, release, &keys, &unreachable)?;

    let file = format!("kix-{system}.tar.gz");
    let expected = verify::sum_for(&sums, &file).ok_or_else(|| InstallError::NotInSums {
        version: v.clone(),
        file: file.clone(),
    })?;

    let tmp = TempDir::create(&data.join(format!("tmp-{v}-{}", std::process::id())))?;
    let archive = tmp.0.join(&file);
    let got = fetcher
        .get_to_file(&format!("{}{file}", release.download), &archive)
        .map_err(|e| e.into_install_error(&unreachable))?;
    if got != expected {
        return Err(InstallError::ShaMismatch {
            file,
            expected,
            got,
        });
    }
    let top = format!("kix-{v}-{system}");
    let unpacked = tmp.0.join("unpacked");
    download::unpack(&archive, &unpacked, &top).map_err(|reason| InstallError::BadArchive {
        version: v.clone(),
        reason,
    })?;
    let new = unpacked.join(&top);
    if !new.join("bin").join("kix").is_file() {
        return Err(InstallError::BadArchive {
            version: v.clone(),
            reason: format!("it has no {top}/bin/kix"),
        });
    }
    let dest = data.join(&v);
    move_into_place(&new, &dest)?;
    Ok(Installed {
        install: Install {
            version: release.version.clone(),
            dir: dest,
        },
        downloaded: true,
    })
}

/// Fetch the `SHA256SUMS` of `release` and check its signature against
/// `keys`. Return its text.
fn verified_sums(
    fetcher: &mut download::Fetcher,
    release: &index::Release,
    keys: &[(String, [u8; 32])],
    unreachable: &dyn Fn(String) -> InstallError,
) -> Result<String, InstallError> {
    let v = release.version.release();
    let no_signature = || InstallError::NoSignature { version: v.clone() };
    let sig_path = release.signature.as_deref().ok_or_else(no_signature)?;
    let sig_text = match fetcher.get(sig_path) {
        Ok(bytes) => bytes,
        Err(download::FetchError::NotFound(_)) => return Err(no_signature()),
        Err(e) => return Err(e.into_install_error(unreachable)),
    };
    let sums = fetcher
        .get(&release.sums)
        .map_err(|e| e.into_install_error(unreachable))?;
    let bad_signature = |reason| InstallError::BadSignature {
        version: v.clone(),
        reason,
    };
    let signature =
        verify::parse_signature(&String::from_utf8_lossy(&sig_text)).map_err(bad_signature)?;
    verify::verify_sums(&sums, &signature, keys).map_err(bad_signature)?;
    Ok(String::from_utf8_lossy(&sums).into_owned())
}

/// Return the release index at `source`.
pub fn fetch_index(source: &Source) -> Result<index::Index, InstallError> {
    let mut fetcher = download::Fetcher::new(source.clone());
    let bytes = fetcher.get(index::PATH).map_err(|e| {
        e.into_install_error(&|message| InstallError::Download {
            url: format!("{source}{}", index::PATH),
            message,
        })
    })?;
    index::Index::parse(&bytes).map_err(|message| InstallError::BadIndex {
        site: source.to_string(),
        message,
    })
}

/// Return the name of the change records file of Kix `version`.
pub fn changes_file(version: &Version) -> String {
    format!("kix-{}-changes.json", version.release())
}

/// Fetch the change records of `release` from `source`, from the file
/// [`changes_file`] names beside its archives. The file is checked against
/// the signed `SHA256SUMS`. Return `None` when `SHA256SUMS` does not list
/// it, since releases made before change records have none.
pub fn changes(
    source: &Source,
    release: &index::Release,
) -> Result<Option<crate::changes::Document>, InstallError> {
    let keys = verify::trusted_keys(source, std::env::var(verify::TEST_KEY_VAR).ok().as_deref());
    if keys.is_empty() {
        return Err(InstallError::NoKeys);
    }
    let mut fetcher = download::Fetcher::new(source.clone());
    let unreachable = |message: String| InstallError::Download {
        url: source.to_string(),
        message,
    };
    let sums = verified_sums(&mut fetcher, release, &keys, &unreachable)?;
    let file = changes_file(&release.version);
    let Some(expected) = verify::sum_for(&sums, &file) else {
        return Ok(None);
    };
    let bytes = fetcher
        .get(&format!("{}{file}", release.download))
        .map_err(|e| e.into_install_error(&unreachable))?;
    let got = verify::hex(&sha2::Sha256::digest(&bytes));
    if got != expected {
        return Err(InstallError::ShaMismatch {
            file,
            expected,
            got,
        });
    }
    let text = String::from_utf8_lossy(&bytes);
    crate::changes::Document::parse(&text)
        .map(Some)
        .map_err(|e| InstallError::BadChanges {
            version: release.version.release(),
            message: e.to_string(),
        })
}

/// Move the unpacked release at `new` to `dest`. Another process may install
/// the same version at the same time and get there first, so a `dest` that
/// already holds `bin/kix` counts as installed.
fn move_into_place(new: &Path, dest: &Path) -> Result<(), InstallError> {
    let installed = || dest.join("bin").join("kix").is_file();
    if installed() {
        return Ok(());
    }
    match std::fs::rename(new, dest) {
        Ok(()) => Ok(()),
        Err(_) if installed() => Ok(()),
        Err(e) => Err(InstallError::Io {
            path: dest.to_path_buf(),
            source: e,
        }),
    }
}

/// Return the newest release the index at `source` lists for `system` that
/// Kix `running` updates to ([`index::Index::latest_for`]).
pub fn latest(
    source: &Source,
    system: &str,
    running: &Version,
) -> Result<Option<Version>, InstallError> {
    let mut fetcher = download::Fetcher::new(source.clone());
    let bytes = fetcher.get(index::PATH).map_err(|e| {
        e.into_install_error(&|message| InstallError::Download {
            url: format!("{source}{}", index::PATH),
            message,
        })
    })?;
    let index = index::Index::parse(&bytes).map_err(|message| InstallError::BadIndex {
        site: source.to_string(),
        message,
    })?;
    Ok(index.latest_for(system, running).map(|r| r.version.clone()))
}

/// A directory removed when dropped, including read-only trees from an
/// unpacked archive.
struct TempDir(PathBuf);

impl TempDir {
    fn create(path: &Path) -> Result<Self, InstallError> {
        if path.exists() {
            installs::remove_tree(path).map_err(InstallError::io(path))?;
        }
        std::fs::create_dir_all(path).map_err(InstallError::io(path))?;
        Ok(TempDir(path.to_path_buf()))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        if let Err(e) = installs::remove_tree(&self.0) {
            tracing::warn!(path = %self.0.display(), error = %e, "could not remove a download directory");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_supported_machine_has_a_system_name() {
        assert_eq!(system_for("linux", "x86_64").unwrap(), "x86_64-linux");
        assert_eq!(system_for("linux", "aarch64").unwrap(), "aarch64-linux");
        assert_eq!(system_for("macos", "aarch64").unwrap(), "aarch64-darwin");
        let err = system_for("macos", "x86_64").unwrap_err().to_string();
        assert_eq!(
            err,
            "Kix has no release for macos x86_64. Supported: x86_64-linux, aarch64-linux, aarch64-darwin"
        );
        assert!(system_for("windows", "x86_64").is_err());
    }

    #[test]
    fn a_version_another_process_installed_first_counts() {
        let tmp = tempfile::tempdir().unwrap();
        let new = tmp.path().join("new");
        std::fs::create_dir_all(new.join("bin")).unwrap();
        std::fs::write(new.join("bin/kix"), "new").unwrap();
        let dest = tmp.path().join("0.9.1");
        std::fs::create_dir_all(dest.join("bin")).unwrap();
        std::fs::write(dest.join("bin/kix"), "first").unwrap();
        std::fs::write(dest.join("other"), "x").unwrap();
        move_into_place(&new, &dest).unwrap();
        assert_eq!(
            std::fs::read_to_string(dest.join("bin/kix")).unwrap(),
            "first"
        );

        // A destination that is not an install is an error.
        let dest = tmp.path().join("0.9.2");
        std::fs::create_dir_all(dest.join("lib")).unwrap();
        std::fs::write(dest.join("lib/x"), "x").unwrap();
        assert!(matches!(
            move_into_place(&new, &dest),
            Err(InstallError::Io { .. })
        ));

        let dest = tmp.path().join("0.9.3");
        move_into_place(&new, &dest).unwrap();
        assert_eq!(
            std::fs::read_to_string(dest.join("bin/kix")).unwrap(),
            "new"
        );
    }

    #[test]
    fn a_missing_release_names_the_newest() {
        let req = Requirement::Minor(0, 9);
        assert_eq!(
            no_release_message(&req.to_string(), "x86_64-linux", Some("0.8.4"), None),
            "no Kix 0.9 release exists for x86_64-linux. The newest release is 0.8.4"
        );
        assert_eq!(
            no_release_message(
                &req.to_string(),
                "x86_64-linux",
                Some("0.8.4"),
                Some("0.9.0-rc.1")
            ),
            "no Kix 0.9 release exists for x86_64-linux. The newest release is 0.8.4. Kix 0.9.0-rc.1 is a prerelease, which Kix installs only when it is named exactly. To install it, run `kix self install 0.9.0-rc.1`"
        );
    }
}
