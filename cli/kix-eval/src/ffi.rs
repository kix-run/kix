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
use std::path::Path;
use std::sync::Once;

use anyhow::{Context, Result};
use nix_bindings_expr::eval_state::{self, EvalState, EvalStateBuilder, ThreadRegistrationGuard};
use nix_bindings_expr::value::ValueType;
use nix_bindings_fetchers::FetchersSettings;
use nix_bindings_flake::{EvalStateBuilderExt, FlakeSettings};
use nix_bindings_store::store::Store;
use nix_bindings_util::settings;
use serde_json::Value;

use crate::error::KixEvalError;
use crate::eval::{ClusterOutput, NixBackend};

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
/// SAFETY: This type wraps Nix C pointers that are not Send/Sync by default.
/// We guarantee single-threaded access — all evaluation happens on one thread.
/// The KixEvaluator wraps this behind a non-shared mutable reference.
pub struct FfiNixBackend {
    eval_state: EvalState,
    // Kept alive for the lifetime of the backend (Nix requires them).
    _flake_settings: FlakeSettings,
    _fetchers_settings: FetchersSettings,
}

// SAFETY: FfiNixBackend is only used from a single thread (the main eval thread).
// The NixBackend trait requires Send for boxing, but we never actually send it
// across threads — KixEvaluator holds it as Box<dyn NixBackend> and uses &mut self.
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
            _flake_settings: flake_settings,
            _fetchers_settings: fetchers_settings,
        })
    }

    // NOTE: eval_flake via FlakeReference API is available for future use
    // when we want to avoid eval_from_string. For now, eval_from_string with
    // builtins.getFlake is simpler and handles the flake-parts output structure.

    /// Classify a Nix evaluation error as either ClusterNotFound or a generic eval error.
    fn classify_eval_error(
        e: impl Into<anyhow::Error>,
        flake: &str,
        cluster_name: &str,
    ) -> KixEvalError {
        let err = e.into();
        let msg = format!("{}", err);
        // Nix attribute-missing errors contain "missing" or the attribute name
        // with "does not exist" / "not found" depending on the Nix version.
        if msg.contains("missing attribute")
            || msg.contains("does not exist")
            || (msg.contains(cluster_name) && msg.contains("not found"))
        {
            KixEvalError::not_found(cluster_name)
        } else {
            KixEvalError::eval(flake.to_string(), cluster_name, err)
        }
    }
}

impl NixBackend for FfiNixBackend {
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        // Reject obviously invalid names before hitting Nix (which is slow).
        // Cluster names are Nix attribute identifiers: alphanumeric, hyphens, underscores.
        if !cluster_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(KixEvalError::not_found(cluster_name));
        }
        tracing::info!(cluster = cluster_name, "evaluating cluster");

        let flake_str = flake_path.to_string_lossy();

        // Evaluate cluster rawManifests via the flake's legacyPackages output.
        // The flake exposes: legacyPackages.<system>.kixClusters.<name>
        let raw_manifests_expr = format!(
            r#"
            let
              flake = builtins.getFlake "path:{}";
              sys = builtins.currentSystem;
            in builtins.toJSON flake.legacyPackages.${{sys}}.kixClusters.{}.rawManifests
            "#,
            flake_str, cluster_name
        );

        // Use eval_from_string for the expression.
        // Attribute-missing errors surface either here or during force(),
        // so we check both for "not found" patterns.
        let json_value = self
            .eval_state
            .eval_from_string(&raw_manifests_expr, ".")
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;
        tracing::debug!(cluster = cluster_name, "expression parsed");

        // Force evaluation — attribute errors often surface here rather than
        // during initial parse.
        self.eval_state
            .force(&json_value)
            .map_err(|e| Self::classify_eval_error(e, &flake_str, cluster_name))?;
        tracing::debug!(cluster = cluster_name, "evaluation forced");

        // Get the JSON string
        let json_str = self
            .eval_state
            .require_string(&json_value)
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), cluster_name, e))?;

        // Parse JSON into manifests
        let raw_manifests: Vec<Value> = serde_json::from_str(&json_str).map_err(|e| {
            KixEvalError::eval(
                flake_str.to_string(),
                cluster_name,
                anyhow::anyhow!("failed to parse manifest JSON: {}", e),
            )
        })?;
        tracing::debug!(
            cluster = cluster_name,
            manifests = raw_manifests.len(),
            "manifests parsed"
        );

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        tracing::debug!("listing available clusters");
        let flake_str = flake_path.to_string_lossy();

        let expr = format!(
            r#"
            let
              flake = builtins.getFlake "path:{}";
              sys = builtins.currentSystem;
            in builtins.toJSON (builtins.attrNames flake.legacyPackages.${{sys}}.kixClusters)
            "#,
            flake_str
        );

        let json_value = self
            .eval_state
            .eval_from_string(&expr, ".")
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), "list_clusters", e))?;

        self.eval_state
            .force(&json_value)
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), "list_clusters", e))?;

        let json_str = self
            .eval_state
            .require_string(&json_value)
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), "list_clusters", e))?;

        let names: Vec<String> = serde_json::from_str(&json_str).map_err(|e| {
            KixEvalError::eval(
                flake_str.to_string(),
                "list_clusters",
                anyhow::anyhow!("failed to parse cluster names: {}", e),
            )
        })?;
        tracing::debug!(count = names.len(), "clusters found");

        Ok(names)
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
