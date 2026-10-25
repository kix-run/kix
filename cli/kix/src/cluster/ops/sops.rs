//! [`SecretHydrator`] through `sops`.

use async_trait::async_trait;
use serde_json::Value;

use super::super::secrets::{self, HydrationResult, SecretError};
use super::SecretHydrator;
use crate::build_source::SopsSources;

/// Decrypts SOPS-backed Secret data with the `sops` binary.
pub(crate) struct SopsHydrator {
    /// Where SOPS sources come from: this machine, or the files a build
    /// carries.
    sources: SopsSources,
}

impl SopsHydrator {
    pub(crate) fn new(sources: SopsSources) -> Self {
        SopsHydrator { sources }
    }
}

#[async_trait]
impl SecretHydrator for SopsHydrator {
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError> {
        // `sops` is a synchronous subprocess. On a blocking thread it cannot
        // stall the runtime; the engine's own thread never runs it.
        let sources = self.sources.clone();
        tokio::task::spawn_blocking(move || {
            let mut single = [manifest];
            let results = secrets::hydrate_secrets_from(&mut single, &sources)?;
            let [manifest] = single;
            Ok((manifest, results))
        })
        .await
        .unwrap_or_else(|join| {
            Err(SecretError::DecryptionFailed {
                path: String::new(),
                message: format!("hydration task failed: {join}"),
            })
        })
    }
}
