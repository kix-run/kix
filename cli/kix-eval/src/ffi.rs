//! Real Nix FFI backend using nix-bindings-rust.
//!
//! Evaluates flake attributes directly via the Nix C API.
//! No subprocess, no shell-out — pure FFI.

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
        gc_register_current_thread().map_err(KixEvalError::init)?;

        // Enable flakes
        settings::set("experimental-features", "flakes nix-command pipe-operators").map_err(KixEvalError::init)?;

        let flake_settings = FlakeSettings::new().map_err(KixEvalError::init)?;
        let fetchers_settings = FetchersSettings::new().map_err(KixEvalError::init)?;

        // Open default store
        let store = Store::open(None, []).map_err(|e| KixEvalError::store("default", e))?;

        // Build eval state with flake support
        let eval_state = EvalStateBuilder::new(store)
            .map_err(KixEvalError::init)?
            .flakes(&flake_settings)
            .map_err(KixEvalError::init)?
            .build()
            .map_err(KixEvalError::init)?;

        Ok(Self {
            eval_state,
            _flake_settings: flake_settings,
            _fetchers_settings: fetchers_settings,
        })
    }

    // NOTE: eval_flake via FlakeReference API is available for future use
    // when we want to avoid eval_from_string. For now, eval_from_string with
    // builtins.getFlake is simpler and handles the flake-parts output structure.
}

impl NixBackend for FfiNixBackend {
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
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

        // Use eval_from_string for the expression
        let json_value = self
            .eval_state
            .eval_from_string(&raw_manifests_expr, ".")
            .map_err(|e| {
                let msg = format!("{}", e);
                if msg.contains("attribute") && msg.contains("missing") {
                    KixEvalError::not_found(cluster_name)
                } else {
                    KixEvalError::eval(flake_str.to_string(), cluster_name, e)
                }
            })?;

        // Force evaluation
        self.eval_state
            .force(&json_value)
            .map_err(|e| KixEvalError::eval(flake_str.to_string(), cluster_name, e))?;

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

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
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
