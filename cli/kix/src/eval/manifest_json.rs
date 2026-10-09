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

/// A manifest or index that [`parse_manifest`] refused. Its strings may
/// hold text kix did not write, and its message shows them through
/// [`printable`].
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("{} is not a JSON manifest: {}", printable(.path), printable(.message))]
pub struct NotJson {
    pub path: String,
    pub message: String,
}

/// `bytes`, the manifest at `path`, parsed as JSON: the one parser for
/// manifests and indexes. Refuses a key given twice and a key with
/// serde_json's reserved prefix; serde_json refuses nesting past 128. An
/// integer outside `i64` and `u64` reads as the nearest `f64`.
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

/// `kix-packages.json` at `path`, parsed with [`parse_manifest`].
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
