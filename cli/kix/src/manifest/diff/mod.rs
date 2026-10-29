//! Structural diff engine for K8s manifests.
//!
//! Custom differ on `serde_json::Value` with keyed-list matching
//! and path-based ignore patterns.

pub mod display;
pub(crate) mod engine;
pub(crate) mod equivalence;
pub(crate) mod ignore;
pub(crate) mod keyed_lists;

use std::collections::BTreeSet;

use serde_json::Value;

/// The type of structural difference between two values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffKind {
    /// Key exists in A but not B.
    MissingInB,
    /// Key exists in B but not A.
    ExtraInB,
    /// Both have the key but values differ.
    ValueMismatch,
    /// Same key, different JSON types.
    TypeMismatch,
}

/// A single structural difference at a specific JSON path.
#[derive(Debug, Clone, PartialEq)]
pub struct Difference {
    /// JSON path where the difference occurs (e.g. `$.spec.replicas`).
    pub path: String,
    /// What kind of difference this is.
    pub kind: DiffKind,
    /// Value from side A (if applicable).
    pub a_value: Option<Value>,
    /// Value from side B (if applicable).
    pub b_value: Option<Value>,
}

impl Difference {
    pub(crate) fn missing_in_b(path: String, a_value: Value) -> Self {
        Self {
            path,
            kind: DiffKind::MissingInB,
            a_value: Some(a_value),
            b_value: None,
        }
    }

    pub(crate) fn extra_in_b(path: String, b_value: Value) -> Self {
        Self {
            path,
            kind: DiffKind::ExtraInB,
            a_value: None,
            b_value: Some(b_value),
        }
    }

    pub(crate) fn value_mismatch(path: String, a_value: Value, b_value: Value) -> Self {
        Self {
            path,
            kind: DiffKind::ValueMismatch,
            a_value: Some(a_value),
            b_value: Some(b_value),
        }
    }

    pub(crate) fn type_mismatch(path: String, a_value: Value, b_value: Value) -> Self {
        Self {
            path,
            kind: DiffKind::TypeMismatch,
            a_value: Some(a_value),
            b_value: Some(b_value),
        }
    }
}

/// Configuration for the diff engine.
#[derive(Debug, Clone)]
pub struct DiffConfig {
    /// JSON path patterns to ignore. Supports exact match and suffix wildcard (`*.annotations`).
    pub ignore_paths: BTreeSet<String>,
    /// Label for side A in output (e.g. "kix").
    pub a_label: String,
    /// Label for side B in output (e.g. "cluster").
    pub b_label: String,
    /// A list in a different order is a difference. Set it when both sides
    /// are what kix writes: the API server stores a list in the order it is
    /// sent, even one it merges by key, and `args` or a route list reads
    /// first to last. Leave it off against a live object, whose merged
    /// lists another manager may have reordered.
    pub ordered: bool,
}

impl Default for DiffConfig {
    fn default() -> Self {
        Self {
            ignore_paths: BTreeSet::new(),
            a_label: "a".to_string(),
            b_label: "b".to_string(),
            ordered: false,
        }
    }
}

impl DiffConfig {
    /// Construct a `DiffConfig` with the given side A and side B labels.
    pub fn new(a_label: impl Into<String>, b_label: impl Into<String>) -> Self {
        Self {
            ignore_paths: BTreeSet::new(),
            a_label: a_label.into(),
            b_label: b_label.into(),
            ordered: false,
        }
    }

    /// Return this config with list order comparison enabled; see [`DiffConfig::ordered`].
    pub(crate) fn in_order(self) -> Self {
        Self {
            ordered: true,
            ..self
        }
    }
}
