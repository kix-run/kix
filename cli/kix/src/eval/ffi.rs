//! Real Nix FFI backend using nix-bindings-rust.
//!
//! Evaluates flake attributes directly via the Nix C API.
//! No subprocess, no shell-out — pure FFI.
//!
//! # Build requirements
//!
//! This module requires the Nix C libraries to be available via pkg-config.
//! In development, `devenv shell` provides them automatically via `pkgs.nix.libs.*`.
//! The nix-bindings-* crates are from the mainline `nixops4/nix-bindings-rust`
//! repo (not the cachix fork) — the mainline has the flake API we need.
//!
//! # Key decisions
//!
//! - We use `eval_from_string` with `builtins.getFlake` rather than the
//!   FlakeReference/LockedFlake API. This is simpler and correctly handles
//!   flake-parts output structure (perSystem is a function, not a direct attrset).
//!
//! - Values are converted to JSON via `builtins.toJSON` in Nix, then parsed
//!   with serde_json. This is simpler than walking the Nix value tree manually
//!   and handles all edge cases (string contexts, thunks, etc.) correctly.
//!   The `nix_value_to_json` function exists for future use if we need
//!   fine-grained value access without full serialization.
//!
//! # Threading
//!
//! Nix uses Boehm GC. Every thread touching Nix values MUST register via
//! `gc_register_my_thread()`. The RAII guard is stored in thread-local storage
//! to keep the thread registered for its lifetime. Init MUST happen before
//! registration (`nix_init()` is called first via `Once`).

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::Once;

use anyhow::{Context, Result};
use nix_bindings_expr::eval_state::{self, EvalState, EvalStateBuilder, ThreadRegistrationGuard};
use nix_bindings_expr::value::ValueType;
use nix_bindings_fetchers::FetchersSettings;
use nix_bindings_flake::{
    EvalStateBuilderExt, FlakeLockFlags, FlakeReference, FlakeReferenceParseFlags, FlakeSettings,
    LockedFlake,
};
use nix_bindings_store::store::Store;
use nix_bindings_util::settings;
use serde_json::Value;

use super::error::KixEvalError;
use super::evaluator::{ClusterOutput, ClusterPackageInfo, NixBackend, PackageInfo};

static NIX_INIT: Once = Once::new();

thread_local! {
    static GC_REGISTRATION: RefCell<Option<ThreadRegistrationGuard>> = const { RefCell::new(None) };
}

/// Initialize the Nix runtime (once per process).
fn nix_init() {
    NIX_INIT.call_once(|| {
        eval_state::init().expect("Failed to initialize Nix expression library");
    });
}

/// Register the current thread with the Boehm GC.
fn gc_register_current_thread() -> Result<()> {
    nix_init();
    GC_REGISTRATION.with(|reg| {
        let mut guard = reg.borrow_mut();
        if guard.is_none() {
            match eval_state::gc_register_my_thread() {
                Ok(registration) => {
                    *guard = Some(registration);
                    Ok(())
                }
                Err(e) => Err(anyhow::anyhow!("Failed to register thread with GC: {}", e)),
            }
        } else {
            Ok(())
        }
    })
}

/// Real Nix FFI backend.
///
/// Uses the `LockedFlake` API to participate in Nix's built-in eval cache
/// (`~/.cache/nix/eval-cache-v*/`). This makes repeated evaluations fast —
/// attribute names and values are cached by Nix itself, unlike the previous
/// `eval_from_string` + `builtins.getFlake` approach which bypassed the cache.
///
/// SAFETY: This type wraps Nix C pointers that are not Send/Sync by default.
/// We guarantee single-threaded access — all evaluation happens on one thread.
/// The KixEvaluator wraps this behind a non-shared mutable reference.
pub struct FfiNixBackend {
    eval_state: EvalState,
    flake_settings: FlakeSettings,
    fetchers_settings: FetchersSettings,
    /// Cached flake outputs for the most recently locked flake path.
    /// Avoids re-locking the flake on every eval_cluster/list_clusters call
    /// within the same CLI invocation.
    cached_outputs: Option<CachedFlakeOutputs>,
}

/// Cached LockedFlake and its outputs Value for a specific flake path.
struct CachedFlakeOutputs {
    flake_path: PathBuf,
    /// The locked flake — kept alive so the outputs Value remains valid.
    _locked_flake: LockedFlake,
    /// The lazy outputs attrset from `locked_flake.outputs()`.
    outputs: nix_bindings_expr::value::Value,
}

// SAFETY: FfiNixBackend wraps Nix C pointers (via EvalState) that are not Send.
// We guarantee single-threaded access through these invariants:
// 1. KixEvaluator holds this as Box<dyn NixBackend> behind &mut self — no shared access.
// 2. eval_cluster() and list_clusters() are the only entry points; both take &mut self.
// 3. The NixBackend trait requires Send for boxing, but the evaluator is never moved
//    across threads — it lives on the main thread for its entire lifetime.
unsafe impl Send for FfiNixBackend {}

impl FfiNixBackend {
    /// Create a new FFI backend.
    ///
    /// Opens a store and creates an EvalState with flake support.
    pub fn new() -> Result<Self, KixEvalError> {
        tracing::debug!("initializing Nix runtime");
        gc_register_current_thread().map_err(KixEvalError::init)?;
        tracing::debug!("GC thread registered");

        // Enable flakes
        settings::set("experimental-features", "flakes nix-command pipe-operators")
            .map_err(KixEvalError::init)?;
        tracing::debug!("experimental features enabled");

        let flake_settings = FlakeSettings::new().map_err(KixEvalError::init)?;
        let fetchers_settings = FetchersSettings::new().map_err(KixEvalError::init)?;

        // Open default store
        let store = Store::open(None, []).map_err(|e| KixEvalError::store("default", e))?;
        tracing::debug!("Nix store opened");

        // Build eval state with flake support
        let eval_state = EvalStateBuilder::new(store)
            .map_err(KixEvalError::init)?
            .flakes(&flake_settings)
            .map_err(KixEvalError::init)?
            .build()
            .map_err(KixEvalError::init)?;
        tracing::debug!("eval state ready");

        Ok(Self {
            eval_state,
            flake_settings,
            fetchers_settings,
            cached_outputs: None,
        })
    }

    /// Ensure the cached flake outputs are populated for the given flake path.
    ///
    /// Uses the `LockedFlake` API which participates in Nix's eval cache.
    /// The outputs are lazy — only attributes that are actually accessed get evaluated.
    fn ensure_flake_outputs(&mut self, flake_path: &Path) -> Result<(), KixEvalError> {
        // Already cached for this path?
        if let Some(ref cached) = self.cached_outputs {
            if cached.flake_path == flake_path {
                return Ok(());
            }
        }

        let flake_str = flake_path.to_string_lossy();
        validate_nix_string_safe(&flake_str, "lock_flake")?;

        tracing::debug!(flake = %flake_str, "locking flake via LockedFlake API");

        let parse_flags =
            FlakeReferenceParseFlags::new(&self.flake_settings).map_err(KixEvalError::init)?;
        let lock_flags = FlakeLockFlags::new(&self.flake_settings).map_err(KixEvalError::init)?;

        let (flake_ref, _fragment) = FlakeReference::parse_with_fragment(
            &self.fetchers_settings,
            &self.flake_settings,
            &parse_flags,
            &format!("path:{}", flake_str),
        )
        .map_err(|e| KixEvalError::eval(flake_str.to_string(), "lock_flake", e))?;

        let locked_flake = LockedFlake::lock(
            &self.fetchers_settings,
            &self.flake_settings,
            &self.eval_state,
            &lock_flags,
            &flake_ref,
        )
        .map_err(|e| KixEvalError::eval(flake_str.to_string(), "lock_flake", e))?;
        tracing::debug!("flake locked");

        let outputs = locked_flake
            .outputs(&self.flake_settings, &mut self.eval_state)
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), "get_outputs", e))?;
        tracing::debug!("flake outputs obtained (lazy)");

        self.cached_outputs = Some(CachedFlakeOutputs {
            flake_path: flake_path.to_path_buf(),
            _locked_flake: locked_flake,
            outputs,
        });

        Ok(())
    }

    /// Get cached flake outputs. Must call `ensure_flake_outputs` first.
    fn flake_outputs(&self) -> &nix_bindings_expr::value::Value {
        &self
            .cached_outputs
            .as_ref()
            .expect("ensure_flake_outputs not called")
            .outputs
    }

    /// Navigate from flake outputs down to `legacyPackages.<system>.kixClusters`.
    fn get_kix_clusters(
        &mut self,
        flake_path: &Path,
    ) -> Result<nix_bindings_expr::value::Value, KixEvalError> {
        let flake_str = flake_path.to_string_lossy().to_string();

        // Get current system
        let sys_value = self
            .eval_state
            .eval_from_string("builtins.currentSystem", ".")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "currentSystem", e))?;
        let system = self
            .eval_state
            .require_string(&sys_value)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "currentSystem", e))?;

        self.ensure_flake_outputs(flake_path)?;
        let outputs = self.flake_outputs().clone();

        let legacy_pkgs = self
            .eval_state
            .require_attrs_select(&outputs, "legacyPackages")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "legacyPackages", e))?;

        let per_system = self
            .eval_state
            .require_attrs_select(&legacy_pkgs, &system)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), &system, e))?;

        self.eval_state
            .require_attrs_select(&per_system, "kixClusters")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "kixClusters", e))
    }

    /// Classify a Nix evaluation error as either ClusterNotFound or a generic eval error.
    fn classify_eval_error(
        e: impl Into<anyhow::Error>,
        flake: &str,
        cluster_name: &str,
    ) -> KixEvalError {
        let err = e.into();
        let msg = format!("{}", err);
        // Nix attribute errors vary by version:
        //   "attribute 'foo' missing" (Nix 2.28+)
        //   "missing attribute 'foo'" (older)
        //   "does not exist" (some contexts)
        if (msg.contains("attribute") && msg.contains("missing"))
            || msg.contains("does not exist")
            || (msg.contains(cluster_name) && msg.contains("not found"))
        {
            KixEvalError::not_found(cluster_name)
        } else {
            KixEvalError::eval(flake.to_string(), cluster_name, err)
        }
    }
}

/// Validate that a string is safe for interpolation into a Nix string literal.
/// Rejects characters that could break out of double-quoted Nix strings.
fn validate_nix_string_safe(s: &str, context: &str) -> Result<(), KixEvalError> {
    if s.contains('"') || s.contains('\\') || s.contains('$') {
        return Err(KixEvalError::eval(
            s.to_string(),
            context,
            anyhow::anyhow!(
                "path contains characters unsafe for Nix string interpolation: {}",
                s
            ),
        ));
    }
    Ok(())
}

impl NixBackend for FfiNixBackend {
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        if !cluster_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(KixEvalError::not_found(cluster_name));
        }
        tracing::info!(cluster = cluster_name, "evaluating cluster");
        let flake_str = flake_path.to_string_lossy().to_string();

        let kix_clusters = self.get_kix_clusters(flake_path)?;

        let cluster = self
            .eval_state
            .require_attrs_select(&kix_clusters, cluster_name)
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;

        let raw_manifests_value = self
            .eval_state
            .require_attrs_select(&cluster, "rawManifests")
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;

        // Force and convert the manifests list to JSON via value tree walking.
        let raw_manifests_json = nix_value_to_json(&mut self.eval_state, &raw_manifests_value)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), cluster_name, e))?;

        let raw_manifests: Vec<Value> = match raw_manifests_json {
            Value::Array(arr) => arr,
            other => {
                return Err(KixEvalError::eval(
                    flake_str,
                    cluster_name,
                    anyhow::anyhow!(
                        "expected rawManifests to be a list, got {}",
                        match &other {
                            Value::Null => "null",
                            Value::Bool(_) => "bool",
                            Value::Number(_) => "number",
                            Value::String(_) => "string",
                            Value::Object(_) => "attrset",
                            Value::Array(_) => unreachable!(),
                        }
                    ),
                ));
            }
        };

        tracing::debug!(
            cluster = cluster_name,
            manifests = raw_manifests.len(),
            "manifests parsed"
        );

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests,
            scorecard_report: None,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        tracing::debug!("listing available clusters");

        let kix_clusters = self.get_kix_clusters(flake_path)?;

        let names = self
            .eval_state
            .require_attrs_names(&kix_clusters)
            .map_err(|e| {
                KixEvalError::eval(flake_path.to_string_lossy().to_string(), "list_clusters", e)
            })?;
        tracing::debug!(count = names.len(), "clusters found");

        Ok(names)
    }

    fn list_packages(
        &mut self,
        flake_path: &Path,
    ) -> Result<std::collections::BTreeMap<String, PackageInfo>, KixEvalError> {
        let flake_str = flake_path.to_string_lossy().to_string();

        self.ensure_flake_outputs(flake_path)?;
        let outputs = self.flake_outputs().clone();

        let sys_value = self
            .eval_state
            .eval_from_string("builtins.currentSystem", ".")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "currentSystem", e))?;
        let system = self
            .eval_state
            .require_string(&sys_value)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "currentSystem", e))?;

        let legacy_pkgs = self
            .eval_state
            .require_attrs_select(&outputs, "legacyPackages")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "legacyPackages", e))?;
        let per_system = self
            .eval_state
            .require_attrs_select(&legacy_pkgs, &system)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), &system, e))?;
        let kix_packages = self
            .eval_state
            .require_attrs_select(&per_system, "kixPackages")
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "kixPackages", e))?;

        let json = nix_value_to_json(&mut self.eval_state, &kix_packages)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), "kixPackages", e))?;

        serde_json::from_value(json).map_err(|e| KixEvalError::StoreGraphError {
            message: format!("failed to parse kixPackages: {e}"),
        })
    }

    fn list_cluster_packages(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError> {
        if !cluster_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(KixEvalError::not_found(cluster_name));
        }
        let flake_str = flake_path.to_string_lossy().to_string();

        let kix_clusters = self.get_kix_clusters(flake_path)?;
        let cluster = self
            .eval_state
            .require_attrs_select(&kix_clusters, cluster_name)
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;
        let info = self
            .eval_state
            .require_attrs_select(&cluster, "info")
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;

        let json = nix_value_to_json(&mut self.eval_state, &info)
            .map_err(|e| KixEvalError::eval(flake_str.clone(), cluster_name, e))?;

        serde_json::from_value(json).map_err(|e| KixEvalError::StoreGraphError {
            message: format!("failed to parse cluster info: {e}"),
        })
    }
}

/// Convert a Nix Value to serde_json::Value by walking the value tree.
#[allow(dead_code)]
fn nix_value_to_json(
    eval: &mut EvalState,
    value: &nix_bindings_expr::value::Value,
) -> Result<Value> {
    eval.force(value).context("forcing value")?;

    match eval.value_type(value).context("getting value type")? {
        ValueType::Null => Ok(Value::Null),
        ValueType::Bool => {
            let b = eval.require_bool(value).context("reading bool")?;
            Ok(Value::Bool(b))
        }
        ValueType::Int => {
            let n = eval.require_int(value).context("reading int")?;
            Ok(Value::Number(n.into()))
        }
        ValueType::Float => {
            let s = eval
                .require_string(value)
                .context("reading float as string")?;
            let f: f64 = s.parse().unwrap_or(0.0);
            Ok(serde_json::Number::from_f64(f)
                .map(Value::Number)
                .unwrap_or(Value::Null))
        }
        ValueType::String => {
            let s = eval.require_string(value).context("reading string")?;
            Ok(Value::String(s))
        }
        ValueType::Path => {
            let s = eval
                .require_string(value)
                .context("reading path as string")?;
            Ok(Value::String(s))
        }
        ValueType::AttrSet => {
            let names = eval.require_attrs_names(value).context("listing attrs")?;
            let mut map = serde_json::Map::new();
            for name in names {
                let child = eval
                    .require_attrs_select(value, &name)
                    .with_context(|| format!("selecting attr '{}'", name))?;
                map.insert(name, nix_value_to_json(eval, &child)?);
            }
            Ok(Value::Object(map))
        }
        ValueType::List => {
            let items: Vec<nix_bindings_expr::value::Value> =
                eval.require_list_strict(value).context("reading list")?;
            let mut arr = Vec::with_capacity(items.len());
            for item in &items {
                arr.push(nix_value_to_json(eval, item)?);
            }
            Ok(Value::Array(arr))
        }
        _ => Ok(Value::Null),
    }
}
