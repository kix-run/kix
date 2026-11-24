//! Query a container registry to resolve an image reference to its manifest digest.
//!
//! This client checks whether a reference exists and returns its manifest
//! digest without pulling layers, inspecting image configuration, or caching.
//! Because resolved digests are committed to a pin file, network requests
//! happen only during pin promotion and never during deployment.
//!
//! The returned digest is the SHA-256 of the manifest bytes served by the
//! registry (the image index digest for multi-architecture images, matching
//! container runtimes and `crane digest`). Kix hashes the response body itself
//! and verifies that `Docker-Content-Digest` agrees when that header is
//! present.

use std::time::Duration;

use sha2::{Digest as _, Sha256};

use super::credentials;
use super::reference::Reference;

/// Manifest media types, in the order a registry should prefer them. Asking
/// for the index types first is what makes a multi-architecture image resolve
/// to its index digest rather than to one platform's manifest.
const MANIFEST_ACCEPT: &str = concat!(
    "application/vnd.oci.image.index.v1+json",
    ",application/vnd.docker.distribution.manifest.list.v2+json",
    ",application/vnd.oci.image.manifest.v1+json",
    ",application/vnd.docker.distribution.manifest.v2+json"
);

const USER_AGENT: &str = concat!("kix/", env!("CARGO_PKG_VERSION"));
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    #[error(
        "{reference} was not found in the registry. Check the repository and tag or digest. The registry returned HTTP 404."
    )]
    NotFound { reference: String },

    #[error(
        "the registry refused the request for {reference}. Credential source: {via}. Check that the credentials have access to this repository. To sign in, run `docker login {registry}`, or set KIX_REGISTRY_USERNAME and KIX_REGISTRY_PASSWORD."
    )]
    Unauthorized {
        reference: String,
        registry: String,
        /// Where Kix looked for credentials, so the message can say what to
        /// fix. Not named `source`: that name means "the underlying error".
        via: &'static str,
    },

    #[error("could not reach the registry for {reference}: {source}")]
    Transport {
        reference: String,
        #[source]
        source: reqwest::Error,
    },

    #[error("the registry answered {status} for {reference}: {body}")]
    Unexpected {
        reference: String,
        status: u16,
        body: String,
    },

    #[error(
        "the registry served a manifest for {reference} whose bytes hash to {computed} but whose Docker-Content-Digest header says {header}. The response is inconsistent, so Kix has not saved a digest. Check the registry or proxy and retry."
    )]
    DigestMismatch {
        reference: String,
        computed: String,
        header: String,
    },

    #[error("image reference is not valid: {0}")]
    BadReference(#[from] super::reference::ReferenceError),
}

/// What a registry said about one reference.
#[derive(Debug, Clone)]
pub struct Resolved {
    /// The reference that was asked about.
    pub reference: Reference,
    /// The manifest digest, `sha256:` followed by 64 hex characters.
    pub digest: String,
}

pub struct RegistryClient {
    http: reqwest::Client,
}

impl RegistryClient {
    pub fn new() -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .timeout(TIMEOUT)
            .build()?;
        Ok(Self { http })
    }

    /// Resolve a reference to its manifest digest.
    ///
    /// When the reference already carries a digest, this asks whether that
    /// digest is still present, which is the check `kix pin check` needs: a
    /// tag can move, a digest cannot, so the digest is the thing worth
    /// verifying.
    pub async fn resolve(&self, reference: &Reference) -> Result<Resolved, RegistryError> {
        let Some(selector) = reference.manifest_selector() else {
            return Err(RegistryError::BadReference(
                super::reference::ReferenceError::NoRepository(reference.to_string()),
            ));
        };

        let url = format!(
            "{}://{}/v2/{}/manifests/{}",
            reference.scheme(),
            reference.api_host(),
            reference.repository,
            selector
        );

        let (creds, source) = credentials::lookup(reference.credential_key());
        let mut token: Option<String> = None;

        // At most two attempts: one anonymous or basic, then one with a
        // bearer token obtained from the challenge the registry returned.
        for attempt in 0..2 {
            let mut req = self.http.get(&url).header("Accept", MANIFEST_ACCEPT);
            if let Some(t) = &token {
                req = req.bearer_auth(t);
            } else if let Some(c) = &creds
                && attempt > 0
            {
                // Only fall back to basic on the second attempt, and only
                // when the registry did not offer a bearer challenge.
                req = req.basic_auth(&c.username, Some(&c.password));
            }

            let resp = req.send().await.map_err(|e| RegistryError::Transport {
                reference: reference.to_string(),
                source: e,
            })?;

            let status = resp.status();

            if status.as_u16() == 401 && attempt == 0 {
                let challenge = resp
                    .headers()
                    .get("www-authenticate")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string);
                if let Some(challenge) = challenge
                    && let Some(bearer) = BearerChallenge::parse(&challenge)
                {
                    token = self.fetch_token(&bearer, reference, creds.as_ref()).await?;
                }
                continue;
            }

            if status.as_u16() == 401 || status.as_u16() == 403 {
                return Err(RegistryError::Unauthorized {
                    reference: reference.to_string(),
                    registry: reference.registry.clone(),
                    via: source.describe(),
                });
            }
            if status.as_u16() == 404 {
                return Err(RegistryError::NotFound {
                    reference: reference.to_string(),
                });
            }

            let header_digest = resp
                .headers()
                .get("docker-content-digest")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);

            if !status.is_success() {
                let body = resp.text().await.unwrap_or_default();
                return Err(RegistryError::Unexpected {
                    reference: reference.to_string(),
                    status: status.as_u16(),
                    body: truncate(&body, 400),
                });
            }

            let bytes = resp.bytes().await.map_err(|e| RegistryError::Transport {
                reference: reference.to_string(),
                source: e,
            })?;
            let computed = format!("sha256:{:x}", Sha256::digest(&bytes));

            if let Some(header) = header_digest
                && header != computed
            {
                return Err(RegistryError::DigestMismatch {
                    reference: reference.to_string(),
                    computed,
                    header,
                });
            }

            return Ok(Resolved {
                reference: reference.clone(),
                digest: computed,
            });
        }

        Err(RegistryError::Unauthorized {
            reference: reference.to_string(),
            registry: reference.registry.clone(),
            via: source.describe(),
        })
    }

    async fn fetch_token(
        &self,
        challenge: &BearerChallenge,
        reference: &Reference,
        creds: Option<&credentials::Credentials>,
    ) -> Result<Option<String>, RegistryError> {
        let scope = challenge
            .scope
            .clone()
            .unwrap_or_else(|| format!("repository:{}:pull", reference.repository));

        let mut req = self.http.get(&challenge.realm).query(&[("scope", &scope)]);
        if let Some(service) = &challenge.service {
            req = req.query(&[("service", service)]);
        }
        if let Some(c) = creds {
            req = req.basic_auth(&c.username, Some(&c.password));
        }

        let resp = req.send().await.map_err(|e| RegistryError::Transport {
            reference: reference.to_string(),
            source: e,
        })?;
        if !resp.status().is_success() {
            // Not fatal on its own: the retry will produce the registry's own
            // refusal, which is a better message than anything invented here.
            return Ok(None);
        }
        let body: serde_json::Value = resp.json().await.map_err(|e| RegistryError::Transport {
            reference: reference.to_string(),
            source: e,
        })?;
        Ok(body
            .get("token")
            .or_else(|| body.get("access_token"))
            .and_then(|v| v.as_str())
            .map(str::to_string))
    }
}

/// The `WWW-Authenticate: Bearer realm="...",service="...",scope="..."` header
/// a registry returns when it wants a token.
#[derive(Debug, PartialEq, Eq)]
struct BearerChallenge {
    realm: String,
    service: Option<String>,
    scope: Option<String>,
}

impl BearerChallenge {
    fn parse(header: &str) -> Option<Self> {
        let rest = header
            .strip_prefix("Bearer ")
            .or_else(|| header.strip_prefix("bearer "))?;
        let mut realm = None;
        let mut service = None;
        let mut scope = None;
        for part in rest.split(',') {
            let (k, v) = part.trim().split_once('=')?;
            let v = v.trim().trim_matches('"').to_string();
            match k.trim() {
                "realm" => realm = Some(v),
                "service" => service = Some(v),
                "scope" => scope = Some(v),
                _ => {}
            }
        }
        Some(Self {
            realm: realm?,
            service,
            scope,
        })
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bearer_challenge_is_parsed_into_its_parts() {
        let c = BearerChallenge::parse(
            r#"Bearer realm="https://auth.example/token",service="registry",scope="repository:a/b:pull""#,
        )
        .expect("parses");
        assert_eq!(c.realm, "https://auth.example/token");
        assert_eq!(c.service.as_deref(), Some("registry"));
        assert_eq!(c.scope.as_deref(), Some("repository:a/b:pull"));
    }

    #[test]
    fn a_challenge_without_a_realm_is_not_usable() {
        assert!(BearerChallenge::parse(r#"Bearer service="registry""#).is_none());
        assert!(BearerChallenge::parse("Basic realm=\"x\"").is_none());
    }

    #[tokio::test]
    async fn a_gzip_encoded_manifest_is_decoded_before_its_digest_is_checked() {
        use std::io::Write as _;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let manifest =
            br#"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}"#;
        let digest = format!("sha256:{:x}", Sha256::digest(manifest));
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(manifest).unwrap();
        let gzipped = encoder.finish().unwrap();

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let registry = listener.local_addr().unwrap().to_string();
        let header = digest.clone();
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut head = Vec::new();
            let mut buf = [0u8; 1024];
            while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = sock.read(&mut buf).await.unwrap();
                assert!(n > 0, "the client closed before sending a request");
                head.extend_from_slice(&buf[..n]);
            }
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.manifest.v1+json\r\n\
                 Content-Encoding: gzip\r\nDocker-Content-Digest: {header}\r\n\
                 Content-Length: {}\r\n\r\n",
                gzipped.len()
            );
            sock.write_all(reply.as_bytes()).await.unwrap();
            sock.write_all(&gzipped).await.unwrap();
            sock.flush().await.unwrap();
            String::from_utf8(head).unwrap().to_ascii_lowercase()
        });

        let reference = Reference::parse(&format!("{registry}/app:v1")).unwrap();
        let resolved = RegistryClient::new()
            .unwrap()
            .resolve(&reference)
            .await
            .unwrap();
        let head = server.await.unwrap();

        assert!(
            head.lines()
                .any(|l| l.starts_with("accept-encoding:") && l.contains("gzip")),
            "the request must ask for gzip:\n{head}"
        );
        assert_eq!(resolved.digest, digest);
    }

    #[test]
    fn a_challenge_may_omit_the_scope() {
        let c =
            BearerChallenge::parse(r#"Bearer realm="https://auth.example/token""#).expect("parses");
        assert!(c.scope.is_none());
    }
}
