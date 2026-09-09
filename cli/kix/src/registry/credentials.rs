//! Finding the username and password for a registry.
//!
//! Kix reads the same places every other container tool reads, in the order
//! they are usually meant to win:
//!
//! 1. `KIX_REGISTRY_USERNAME` and `KIX_REGISTRY_PASSWORD`, for CI that has a
//!    secret in the environment and no reason to run `docker login`.
//! 2. A credential helper named for this registry in `credHelpers`.
//! 3. The general `credsStore` helper, which is what `docker login` uses on
//!    macOS (`osxkeychain`) and on most Linux desktops (`secretservice`).
//! 4. A literal entry under `auths`, which is what `docker login` writes when
//!    no helper is configured, and what a CI runner usually ends up with.
//!
//! Anonymous access is a valid outcome, not a failure. Public images resolve
//! without credentials, and a registry that needs them will say so.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;

use base64::Engine as _;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credentials {
    pub username: String,
    pub password: String,
}

/// Where the credential came from, so an error can say what to fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialSource {
    Environment,
    Helper,
    ConfigFile,
    Anonymous,
}

impl CredentialSource {
    pub fn describe(self) -> &'static str {
        match self {
            Self::Environment => "KIX_REGISTRY_USERNAME and KIX_REGISTRY_PASSWORD",
            Self::Helper => "a Docker credential helper",
            Self::ConfigFile => "the Docker config file",
            Self::Anonymous => "no credentials (anonymous)",
        }
    }
}

#[derive(Debug, Deserialize, Default)]
struct DockerConfig {
    #[serde(default)]
    auths: HashMap<String, AuthEntry>,
    #[serde(rename = "credsStore", default)]
    creds_store: Option<String>,
    #[serde(rename = "credHelpers", default)]
    cred_helpers: HashMap<String, String>,
}

#[derive(Debug, Deserialize, Default)]
struct AuthEntry {
    #[serde(default)]
    auth: Option<String>,
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    password: Option<String>,
}

#[derive(Debug, Deserialize)]
struct HelperOutput {
    #[serde(rename = "Username")]
    username: String,
    #[serde(rename = "Secret")]
    secret: String,
}

/// Look up credentials for a registry. `key` is the registry's credential key
/// (`Reference::credential_key`), which differs from the host for Docker Hub.
pub fn lookup(key: &str) -> (Option<Credentials>, CredentialSource) {
    if let (Ok(username), Ok(password)) = (
        std::env::var("KIX_REGISTRY_USERNAME"),
        std::env::var("KIX_REGISTRY_PASSWORD"),
    ) && !username.is_empty()
    {
        return (
            Some(Credentials { username, password }),
            CredentialSource::Environment,
        );
    }

    let Some(config) = read_config() else {
        return (None, CredentialSource::Anonymous);
    };

    // A helper named for this registry, then the general one.
    let helper = config
        .cred_helpers
        .get(key)
        .or_else(|| config.cred_helpers.get(strip_scheme(key)))
        .or(config.creds_store.as_ref());
    if let Some(helper) = helper
        && let Some(creds) = ask_helper(helper, key)
    {
        return (Some(creds), CredentialSource::Helper);
    }

    // A literal entry. Docker writes the key with and without a scheme
    // depending on its age, so try both spellings.
    let entry = config
        .auths
        .get(key)
        .or_else(|| config.auths.get(strip_scheme(key)));
    if let Some(entry) = entry
        && let Some(creds) = from_entry(entry)
    {
        return (Some(creds), CredentialSource::ConfigFile);
    }

    (None, CredentialSource::Anonymous)
}

fn from_entry(entry: &AuthEntry) -> Option<Credentials> {
    if let Some(auth) = &entry.auth
        && !auth.is_empty()
    {
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(auth)
            .ok()?;
        let decoded = String::from_utf8(decoded).ok()?;
        let (username, password) = decoded.split_once(':')?;
        return Some(Credentials {
            username: username.to_string(),
            password: password.to_string(),
        });
    }
    match (&entry.username, &entry.password) {
        (Some(u), Some(p)) if !u.is_empty() => Some(Credentials {
            username: u.clone(),
            password: p.clone(),
        }),
        _ => None,
    }
}

/// Run `docker-credential-<helper> get`, feeding it the registry on stdin.
/// A helper that does not know the registry exits non-zero or prints
/// `credentials not found`; both mean "try the next source", not "fail".
fn ask_helper(helper: &str, key: &str) -> Option<Credentials> {
    use std::io::Write as _;
    use std::process::Stdio;

    let mut child = Command::new(format!("docker-credential-{helper}"))
        .arg("get")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    child.stdin.as_mut()?.write_all(key.as_bytes()).ok()?;
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    let parsed: HelperOutput = serde_json::from_slice(&out.stdout).ok()?;
    if parsed.username.is_empty() {
        return None;
    }
    Some(Credentials {
        username: parsed.username,
        password: parsed.secret,
    })
}

fn read_config() -> Option<DockerConfig> {
    let path = config_path()?;
    let contents = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

fn config_path() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("DOCKER_CONFIG")
        && !dir.is_empty()
    {
        return Some(PathBuf::from(dir).join("config.json"));
    }
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".docker").join("config.json"))
}

fn strip_scheme(key: &str) -> &str {
    key.strip_prefix("https://")
        .or_else(|| key.strip_prefix("http://"))
        .unwrap_or(key)
        .trim_end_matches('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_auth_splits_into_username_and_password() {
        let auth = base64::engine::general_purpose::STANDARD.encode("robot$ci:s3cret:with:colons");
        let creds = from_entry(&AuthEntry {
            auth: Some(auth),
            ..Default::default()
        })
        .expect("decodes");
        assert_eq!(creds.username, "robot$ci");
        // Only the first colon separates; a password may contain more.
        assert_eq!(creds.password, "s3cret:with:colons");
    }

    #[test]
    fn plain_username_and_password_are_used_when_there_is_no_auth_blob() {
        let creds = from_entry(&AuthEntry {
            username: Some("u".into()),
            password: Some("p".into()),
            ..Default::default()
        })
        .expect("reads");
        assert_eq!(creds.username, "u");
    }

    #[test]
    fn an_empty_entry_yields_nothing_rather_than_empty_credentials() {
        // This is the shape `docker.io` entries take on a machine using a
        // keychain: the entry exists to say "there is a helper for this", and
        // it holds no secret.
        assert!(from_entry(&AuthEntry::default()).is_none());
    }

    #[test]
    fn scheme_and_trailing_slash_are_not_part_of_the_lookup_key() {
        assert_eq!(
            strip_scheme("https://index.docker.io/v1/"),
            "index.docker.io/v1"
        );
        assert_eq!(strip_scheme("harbor.example.com"), "harbor.example.com");
    }
}
