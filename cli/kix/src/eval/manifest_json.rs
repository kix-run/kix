//! The one parser for a build's manifests and its `kix-packages.json`.
//!
//! Every reader of a build parses with [`parse_manifest`]: a result
//! directory (`StoreGraph::from_result_dir`) and a build read from a single
//! file. They must read the same bytes as the same value, so a check made
//! on one reader's value holds for the other's.
//!
//! [`parse_manifest`] refuses a key given twice, a key that starts
//! `$serde_json::private::` (serde_json's `Value`, with the `raw_value`
//! feature this workspace turns on, reads an object with that key as the
//! raw JSON its value holds), and nesting past serde_json's own limit of
//! 128.

use serde::Deserializer;
use serde::de::{DeserializeSeed, Error as _, MapAccess, SeqAccess, Visitor};

use super::store_graph::KixPackageIndex;
use crate::text::printable;

/// Error returned when [`parse_manifest`] rejects a manifest or package index.
/// Formats untrusted strings through [`printable`].
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("{} is not a JSON manifest: {}", printable(.path), printable(.message))]
pub struct NotJson {
    pub path: String,
    pub message: String,
}

/// Parse `bytes` from `path` as a strict JSON manifest.
///
/// Rejects duplicate object keys, keys starting with `serde_json`'s reserved
/// prefix, and nesting deeper than `serde_json`'s limit of 128. Integers
/// outside `i64` and `u64` are parsed as the nearest `f64`.
pub fn parse_manifest(path: &str, bytes: &[u8]) -> Result<serde_json::Value, NotJson> {
    let mut de = serde_json::Deserializer::from_slice(bytes);
    Strict
        .deserialize(&mut de)
        .and_then(|v| de.end().map(|()| v))
        .map_err(|e| NotJson {
            path: path.to_string(),
            message: e.to_string(),
        })
}

/// Parse `kix-packages.json` at `path` using [`parse_manifest`].
pub fn parse_index(path: &str, bytes: &[u8]) -> Result<KixPackageIndex, NotJson> {
    serde_json::from_value(parse_manifest(path, bytes)?).map_err(|e| NotJson {
        path: path.to_string(),
        message: e.to_string(),
    })
}

/// The prefix of the keys serde_json reserves for its own types. With the
/// `raw_value` feature, `serde_json::Value` reads an object whose one key is
/// `$serde_json::private::RawValue` as the JSON text its value holds.
const SERDE_JSON_PRIVATE: &str = "$serde_json::private::";

/// A JSON value parsed by [`parse_manifest`]'s rules.
struct Strict;

impl<'de> DeserializeSeed<'de> for Strict {
    type Value = serde_json::Value;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Strict {
    type Value = serde_json::Value;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_bool<E>(self, v: bool) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_f64<E>(self, v: f64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_string<E>(self, v: String) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(serde_json::Value::Null)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut out = Vec::new();
        while let Some(v) = seq.next_element_seed(Strict)? {
            out.push(v);
        }
        Ok(out.into())
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut out = serde_json::Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if key.starts_with(SERDE_JSON_PRIVATE) {
                return Err(A::Error::custom(format!(
                    "the key '{key}' is reserved by serde_json"
                )));
            }
            if out.contains_key(&key) {
                return Err(A::Error::custom(format!("the key '{key}' is given twice")));
            }
            let value = map.next_value_seed(Strict)?;
            out.insert(key, value);
        }
        Ok(out.into())
    }
}
