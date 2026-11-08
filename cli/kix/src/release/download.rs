//! Fetch release files and unpack a release archive.

use std::io::Write;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

use super::{InstallError, Source};
use crate::version;

/// The largest release archive Kix downloads. A release archive is well
/// under this.
const MAX_ARCHIVE_BYTES: u64 = 500 * 1024 * 1024;

/// The largest index, `SHA256SUMS`, or signature Kix downloads. Each is a
/// few kilobytes, and Kix holds them in memory.
const MAX_TEXT_BYTES: u64 = 1024 * 1024;

/// Why a fetch failed.
#[derive(Debug)]
pub enum FetchError {
    /// The source answered that the file does not exist.
    NotFound(String),
    /// Kix could not reach the source.
    Unreachable(String),
    /// The source answered, but not with the file.
    Failed { url: String, message: String },
    /// Writing the file failed.
    Io(PathBuf, std::io::Error),
}

impl FetchError {
    pub(super) fn into_install_error(
        self,
        unreachable: &dyn Fn(String) -> InstallError,
    ) -> InstallError {
        match self {
            FetchError::Unreachable(message) => unreachable(message),
            FetchError::NotFound(url) => InstallError::Download {
                url,
                message: "it does not exist".to_string(),
            },
            FetchError::Failed { url, message } => InstallError::Download { url, message },
            FetchError::Io(path, source) => InstallError::Io { path, source },
        }
    }
}

/// Fetch files from one [`Source`].
pub struct Fetcher {
    source: Source,
    runtime: Option<(tokio::runtime::Runtime, reqwest::Client)>,
}

impl Fetcher {
    pub fn new(source: Source) -> Self {
        Self {
            source,
            runtime: None,
        }
    }

    /// Return the URL or file `path` names on the source. `path` comes from
    /// the release index, so it must be a site path that stays on the source.
    fn locate(&self, path: &str) -> Result<String, FetchError> {
        let inside = path.starts_with('/')
            && !path.contains("//")
            && !path.split('/').any(|part| part == ".." || part == ".");
        if !inside {
            return Err(FetchError::Failed {
                url: path.to_string(),
                message: format!("the release index names a file outside {}", self.source),
            });
        }
        Ok(match &self.source {
            Source::Https(base) => format!("{base}{path}"),
            Source::Dir(dir) => dir.join(&path[1..]).display().to_string(),
        })
    }

    fn client(&mut self) -> Result<&(tokio::runtime::Runtime, reqwest::Client), FetchError> {
        if self.runtime.is_none() {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| FetchError::Unreachable(e.to_string()))?;
            let client = reqwest::Client::builder()
                .user_agent(format!("kix/{}", version::running().release()))
                .connect_timeout(std::time::Duration::from_secs(15))
                .read_timeout(std::time::Duration::from_secs(60))
                .build()
                .map_err(|e| FetchError::Unreachable(e.to_string()))?;
            self.runtime = Some((runtime, client));
        }
        Ok(self.runtime.as_ref().expect("set above"))
    }

    /// Return the bytes of the small text file at `path`, such as the index.
    pub fn get(&mut self, path: &str) -> Result<Vec<u8>, FetchError> {
        let mut out = Vec::new();
        self.copy(path, &mut out, MAX_TEXT_BYTES)?;
        Ok(out)
    }

    /// Download the file at `path` to `dest` and return its SHA-256 in hex.
    pub fn get_to_file(&mut self, path: &str, dest: &Path) -> Result<String, FetchError> {
        let file = std::fs::File::create(dest).map_err(|e| FetchError::Io(dest.into(), e))?;
        let mut writer = Hashing {
            inner: std::io::BufWriter::new(file),
            hash: Sha256::new(),
        };
        self.copy(path, &mut writer, MAX_ARCHIVE_BYTES)?;
        writer
            .inner
            .flush()
            .map_err(|e| FetchError::Io(dest.into(), e))?;
        Ok(super::verify::hex(&writer.hash.finalize()))
    }

    fn copy(&mut self, path: &str, out: &mut dyn Write, limit: u64) -> Result<(), FetchError> {
        let location = self.locate(path)?;
        match self.source.clone() {
            Source::Dir(_) => {
                let file = match std::fs::File::open(&location) {
                    Ok(file) => file,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                        return Err(FetchError::NotFound(location));
                    }
                    Err(e) => {
                        return Err(FetchError::Failed {
                            url: location,
                            message: e.to_string(),
                        });
                    }
                };
                let copied = std::io::copy(&mut std::io::Read::take(file, limit + 1), out)
                    .map_err(|e| FetchError::Io(location.clone().into(), e))?;
                if copied > limit {
                    return Err(too_large(location, limit));
                }
                Ok(())
            }
            Source::Https(_) => {
                let (runtime, client) = self.client()?;
                runtime.block_on(fetch(client, &location, out, limit))
            }
        }
    }
}

fn too_large(url: String, limit: u64) -> FetchError {
    FetchError::Failed {
        url,
        message: format!("it is larger than {} MB", limit / 1024 / 1024),
    }
}

async fn fetch(
    client: &reqwest::Client,
    url: &str,
    out: &mut dyn Write,
    limit: u64,
) -> Result<(), FetchError> {
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|e| FetchError::Unreachable(error_chain(&e)))?;
    let status = response.status();
    if status == reqwest::StatusCode::NOT_FOUND {
        return Err(FetchError::NotFound(url.to_string()));
    }
    if !status.is_success() {
        return Err(FetchError::Failed {
            url: url.to_string(),
            message: format!("the server answered {status}"),
        });
    }
    let mut written: u64 = 0;
    while let Some(chunk) = response.chunk().await.map_err(|e| FetchError::Failed {
        url: url.to_string(),
        message: error_chain(&e),
    })? {
        written += chunk.len() as u64;
        if written > limit {
            return Err(too_large(url.to_string(), limit));
        }
        out.write_all(&chunk)
            .map_err(|e| FetchError::Io(PathBuf::from(url), e))?;
    }
    Ok(())
}

/// Return an error and its causes on one line. reqwest's own message names
/// only the request, and the cause says why it failed.
fn error_chain(e: &dyn std::error::Error) -> String {
    let mut text = e.to_string();
    let mut source = e.source();
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

struct Hashing<W> {
    inner: W,
    hash: Sha256,
}

impl<W: Write> Write for Hashing<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.hash.update(&buf[..n]);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Unpack the gzip tar archive at `archive` into `dest`, after checking that
/// every entry sits under the directory `top` and that every link points
/// inside it. Return the reason when the archive breaks either rule.
pub fn unpack(archive: &Path, dest: &Path, top: &str) -> Result<(), String> {
    let open = || {
        std::fs::File::open(archive)
            .map(|f| tar::Archive::new(flate2::read::GzDecoder::new(f)))
            .map_err(|e| e.to_string())
    };
    check_entries(&mut open()?, top)?;
    std::fs::create_dir_all(dest).map_err(|e| e.to_string())?;
    let mut tar = open()?;
    tar.set_preserve_permissions(false);
    tar.set_overwrite(false);
    tar.unpack(dest).map_err(|e| e.to_string())
}

fn check_entries<R: std::io::Read>(tar: &mut tar::Archive<R>, top: &str) -> Result<(), String> {
    let entries = tar.entries().map_err(|e| e.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path().map_err(|e| e.to_string())?.into_owned();
        let shown = path.display().to_string();
        let parts = normal_parts(&path).ok_or_else(|| format!("it holds the path {shown}"))?;
        if parts.first().map(String::as_str) != Some(top) {
            return Err(format!("{shown} is outside {top}/"));
        }
        let kind = entry.header().entry_type();
        if kind.is_symlink() || kind.is_hard_link() {
            let target = entry
                .link_name()
                .map_err(|e| e.to_string())?
                .ok_or_else(|| format!("the link {shown} has no target"))?
                .into_owned();
            // A hard link names a path from the archive root, and a symbolic
            // link names one from the link's own directory.
            let base = if kind.is_hard_link() {
                Vec::new()
            } else {
                parts[..parts.len() - 1].to_vec()
            };
            if !stays_inside(&base, &target, top) {
                return Err(format!(
                    "the link {shown} points to {}, outside {top}/",
                    target.display()
                ));
            }
        } else if !(kind.is_file() || kind.is_dir()) {
            return Err(format!("{shown} is not a file, directory, or link"));
        }
    }
    Ok(())
}

/// Return the components of a relative path without `.`, or `None` for an
/// absolute path or one that climbs with `..`.
fn normal_parts(path: &Path) -> Option<Vec<String>> {
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(p) => parts.push(p.to_str()?.to_string()),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!parts.is_empty()).then_some(parts)
}

/// Return whether `target`, read from the directory `base`, stays inside the
/// directory `top` at the archive root.
fn stays_inside(base: &[String], target: &Path, top: &str) -> bool {
    let mut at: Vec<&str> = base.iter().map(String::as_str).collect();
    for component in target.components() {
        match component {
            Component::Normal(p) => match p.to_str() {
                Some(p) => at.push(p),
                None => return false,
            },
            Component::CurDir => {}
            Component::ParentDir => {
                at.pop();
                if at.is_empty() {
                    return false;
                }
            }
            Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    at.first() == Some(&top)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a gzip tar archive. Each entry is a path and either file
    /// contents or `->target` for a symbolic link.
    fn archive(dir: &Path, entries: &[(&str, &str)]) -> PathBuf {
        let path = dir.join("a.tar.gz");
        let gz = flate2::write::GzEncoder::new(
            std::fs::File::create(&path).unwrap(),
            flate2::Compression::fast(),
        );
        let mut tar = tar::Builder::new(gz);
        for (name, body) in entries {
            let mut header = tar::Header::new_gnu();
            if let Some(target) = body.strip_prefix("->") {
                header.set_entry_type(tar::EntryType::Symlink);
                header.set_size(0);
                header.set_mode(0o777);
                // `set_link_name` refuses `..`, which the tests need, so
                // write the raw field.
                let raw = &mut header.as_old_mut().linkname;
                raw[..target.len()].copy_from_slice(target.as_bytes());
                set_raw_path(&mut header, name);
                header.set_cksum();
                tar.append(&header, std::io::empty()).unwrap();
            } else {
                header.set_size(body.len() as u64);
                header.set_mode(0o755);
                set_raw_path(&mut header, name);
                header.set_cksum();
                tar.append(&header, body.as_bytes()).unwrap();
            }
        }
        tar.into_inner().unwrap().finish().unwrap();
        path
    }

    /// Write `name` into the header as it is, since `set_path` refuses `..`
    /// and absolute paths.
    fn set_raw_path(header: &mut tar::Header, name: &str) {
        let raw = &mut header.as_old_mut().name;
        raw.fill(0);
        raw[..name.len()].copy_from_slice(name.as_bytes());
    }

    fn check(entries: &[(&str, &str)]) -> Result<(), String> {
        let tmp = tempfile::tempdir().unwrap();
        let path = archive(tmp.path(), entries);
        unpack(&path, &tmp.path().join("out"), "kix-1.0.0-x86_64-linux")
    }

    #[test]
    fn a_release_archive_unpacks() {
        let tmp = tempfile::tempdir().unwrap();
        let path = archive(
            tmp.path(),
            &[
                ("kix-1.0.0-x86_64-linux/bin/kix", "#!/bin/sh\n"),
                ("kix-1.0.0-x86_64-linux/libexec/kix/nix/bin/nix", "nix"),
                (
                    "kix-1.0.0-x86_64-linux/libexec/kix/nix/bin/nix-store",
                    "->nix",
                ),
                ("kix-1.0.0-x86_64-linux/lib/up", "->../bin/kix"),
            ],
        );
        let out = tmp.path().join("out");
        unpack(&path, &out, "kix-1.0.0-x86_64-linux").unwrap();
        let top = out.join("kix-1.0.0-x86_64-linux");
        assert_eq!(
            std::fs::read_to_string(top.join("bin/kix")).unwrap(),
            "#!/bin/sh\n"
        );
        assert_eq!(
            std::fs::read_link(top.join("libexec/kix/nix/bin/nix-store")).unwrap(),
            PathBuf::from("nix")
        );
    }

    #[test]
    fn entries_outside_the_top_directory_are_refused() {
        let err = check(&[("other/bin/kix", "x")]).unwrap_err();
        assert!(err.contains("outside kix-1.0.0-x86_64-linux/"), "{err}");

        let err = check(&[("/etc/kix", "x")]).unwrap_err();
        assert!(err.contains("holds the path /etc/kix"), "{err}");

        let err = check(&[("kix-1.0.0-x86_64-linux/../../evil", "x")]).unwrap_err();
        assert!(err.contains("holds the path"), "{err}");
    }

    #[test]
    fn links_out_of_the_top_directory_are_refused() {
        for target in ["../../etc/passwd", "/etc/passwd", "../..", "../../other/x"] {
            let link = format!("->{target}");
            let err = check(&[("kix-1.0.0-x86_64-linux/bin/x", link.as_str())]).unwrap_err();
            assert!(
                err.contains("outside kix-1.0.0-x86_64-linux/"),
                "{target}: {err}"
            );
        }
    }

    #[test]
    fn a_text_file_over_a_megabyte_is_refused() {
        let site = tempfile::tempdir().unwrap();
        let big = vec![b'x'; MAX_TEXT_BYTES as usize + 1];
        std::fs::write(site.path().join("big"), &big).unwrap();
        std::fs::write(site.path().join("fits"), &big[1..]).unwrap();
        let mut fetcher = Fetcher::new(Source::Dir(site.path().to_path_buf()));
        match fetcher.get("/big") {
            Err(FetchError::Failed { message, .. }) => {
                assert_eq!(message, "it is larger than 1 MB")
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(fetcher.get("/fits").unwrap().len(), big.len() - 1);
        let out = site.path().join("out");
        fetcher.get_to_file("/big", &out).unwrap();
        assert_eq!(std::fs::metadata(&out).unwrap().len(), big.len() as u64);
    }

    #[test]
    fn site_paths_stay_on_the_source() {
        let fetcher = Fetcher::new(Source::Https("https://kix.run".into()));
        assert_eq!(
            fetcher.locate("/releases/index.json").unwrap(),
            "https://kix.run/releases/index.json"
        );
        for path in [
            "releases/index.json",
            "https://evil.example/x",
            "//evil.example/x",
            "/releases/../../x",
        ] {
            assert!(fetcher.locate(path).is_err(), "{path}");
        }
        let fetcher = Fetcher::new(Source::Dir("/srv/site".into()));
        assert_eq!(
            fetcher
                .locate("/download/1.0.0/kix-x86_64-linux.tar.gz")
                .unwrap(),
            "/srv/site/download/1.0.0/kix-x86_64-linux.tar.gz"
        );
    }
}
