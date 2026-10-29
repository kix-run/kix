//! Parsing an image reference into the parts a registry API needs.
//!
//! Docker's reference grammar is mostly convention, and the conventions are
//! the part that surprises people: `nginx` means `docker.io/library/nginx`,
//! `myorg/app` means `docker.io/myorg/app`, and `reg.example/app` means what
//! it says. The rule that separates a registry host from the first path
//! segment is that a host contains a dot or a colon, or is exactly
//! `localhost`. Everything else is a repository path.

use std::fmt;

/// The canonical host for Docker Hub's registry API. `docker.io` is the name
/// people write; it is not the host that answers `/v2/`.
const DOCKER_HUB_API: &str = "registry-1.docker.io";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reference {
    /// Registry host as written, e.g. `docker.io` or `harbor.example.com`.
    pub registry: String,
    /// Repository path without the registry, e.g. `library/nginx`.
    pub repository: String,
    /// Tag, when the reference carries one.
    pub tag: Option<String>,
    /// Digest, when the reference carries one.
    pub digest: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ReferenceError {
    #[error("image reference is empty")]
    Empty,
    #[error("image reference '{0}' has no repository")]
    NoRepository(String),
    #[error(
        "image reference '{0}' has a digest that is not sha256: followed by 64 hexadecimal characters"
    )]
    BadDigest(String),
}

impl Reference {
    /// Parse `[registry/]repository[:tag][@digest]`.
    pub fn parse(input: &str) -> Result<Self, ReferenceError> {
        let input = input.trim();
        if input.is_empty() {
            return Err(ReferenceError::Empty);
        }

        let (rest, digest) = match input.split_once('@') {
            Some((r, d)) => {
                if !is_sha256_digest(d) {
                    return Err(ReferenceError::BadDigest(input.to_string()));
                }
                (r, Some(d.to_string()))
            }
            None => (input, None),
        };

        // A colon is only a tag separator when it comes after the last slash;
        // before it, it is a registry port.
        let last_slash = rest.rfind('/').map(|i| i + 1).unwrap_or(0);
        let (name, tag) = match rest[last_slash..].rfind(':') {
            Some(i) => {
                let at = last_slash + i;
                (&rest[..at], Some(rest[at + 1..].to_string()))
            }
            None => (rest, None),
        };

        let (registry, repository) = match name.split_once('/') {
            Some((head, tail)) if is_registry_host(head) => (head.to_string(), tail.to_string()),
            _ => ("docker.io".to_string(), name.to_string()),
        };

        if repository.is_empty() {
            return Err(ReferenceError::NoRepository(input.to_string()));
        }

        // Docker Hub's official images live under `library/`, which nobody
        // writes and every client adds.
        let repository = if registry == "docker.io" && !repository.contains('/') {
            format!("library/{repository}")
        } else {
            repository
        };

        Ok(Self {
            registry,
            repository,
            tag,
            digest,
        })
    }

    /// Build a reference from a repository and a tag that are already apart.
    pub fn from_parts(repository: &str, tag: &str) -> Result<Self, ReferenceError> {
        Self::parse(&format!("{repository}:{tag}"))
    }

    /// Return the hostname to send registry API requests to.
    pub(crate) fn api_host(&self) -> &str {
        if self.registry == "docker.io" {
            DOCKER_HUB_API
        } else {
            &self.registry
        }
    }

    /// Return the key under which credentials for this registry are stored.
    /// Docker Hub uses a historical URL key across credential helpers.
    pub(crate) fn credential_key(&self) -> &str {
        if self.registry == "docker.io" {
            "https://index.docker.io/v1/"
        } else {
            &self.registry
        }
    }

    /// Return `"http"` for loopback registries (such as `localhost:5000`) and
    /// `"https"` for all other hosts.
    pub(crate) fn scheme(&self) -> &'static str {
        let host = self.api_host();
        let bare = host.split(':').next().unwrap_or(host);
        if bare == "localhost" || bare == "127.0.0.1" || bare == "::1" {
            "http"
        } else {
            "https"
        }
    }

    /// Return the manifest identifier to request from the registry: the digest
    /// when present, or the tag otherwise.
    pub(crate) fn manifest_selector(&self) -> Option<&str> {
        self.digest.as_deref().or(self.tag.as_deref())
    }
}

impl fmt::Display for Reference {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/{}", self.registry, self.repository)?;
        if let Some(t) = &self.tag {
            write!(f, ":{t}")?;
        }
        if let Some(d) = &self.digest {
            write!(f, "@{d}")?;
        }
        Ok(())
    }
}

/// Return whether a leading path segment is a registry host (contains a dot or
/// colon, or equals `"localhost"`).
fn is_registry_host(s: &str) -> bool {
    s == "localhost" || s.contains('.') || s.contains(':')
}

/// Return whether `s` is `sha256:` followed by 64 hexadecimal characters.
pub fn is_sha256_digest(s: &str) -> bool {
    match s.strip_prefix("sha256:") {
        Some(hex) => hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Reference {
        Reference::parse(s).expect(s)
    }

    #[test]
    fn bare_name_is_a_docker_hub_official_image() {
        let r = parse("nginx:1.27");
        assert_eq!(r.registry, "docker.io");
        assert_eq!(r.repository, "library/nginx");
        assert_eq!(r.tag.as_deref(), Some("1.27"));
        assert_eq!(r.api_host(), "registry-1.docker.io");
    }

    #[test]
    fn org_name_is_docker_hub_without_the_library_prefix() {
        let r = parse("bitnami/valkey:8.0");
        assert_eq!(r.registry, "docker.io");
        assert_eq!(r.repository, "bitnami/valkey");
    }

    #[test]
    fn a_dotted_first_segment_is_a_registry() {
        let r = parse("registry.example.com/lithus/atlas-server:sha-5d5dda2");
        assert_eq!(r.registry, "registry.example.com");
        assert_eq!(r.repository, "lithus/atlas-server");
    }

    #[test]
    fn a_registry_port_is_not_a_tag() {
        let r = parse("localhost:5000/app:v1");
        assert_eq!(r.registry, "localhost:5000");
        assert_eq!(r.repository, "app");
        assert_eq!(r.tag.as_deref(), Some("v1"));
        assert_eq!(r.scheme(), "http");
    }

    #[test]
    fn digest_and_tag_can_both_be_present() {
        let d = format!("sha256:{}", "ab".repeat(32));
        let r = parse(&format!("reg.example/app:v1@{d}"));
        assert_eq!(r.tag.as_deref(), Some("v1"));
        assert_eq!(r.digest.as_deref(), Some(d.as_str()));
        // A digest wins: it is what the registry will be asked for.
        assert_eq!(r.manifest_selector(), Some(d.as_str()));
    }

    #[test]
    fn a_malformed_digest_is_refused_rather_than_carried() {
        assert!(Reference::parse("reg.example/app@sha256:short").is_err());
        assert!(Reference::parse("").is_err());
    }

    #[test]
    fn display_round_trips_what_was_parsed() {
        for s in [
            "registry.example.com/lithus/app:v1",
            "docker.io/library/nginx:1.27",
        ] {
            assert_eq!(parse(s).to_string(), s);
        }
    }
}
