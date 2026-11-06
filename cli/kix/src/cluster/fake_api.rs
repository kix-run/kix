//! An in-memory apiserver for tests of code that takes a `kube::Client`.
//!
//! It serves discovery for a fixed set of kinds (ConfigMap, Secret, Namespace,
//! ClusterRole, Kix's Activation, and two kinds of a group served at two
//! versions), and GET, LIST (with an equality label
//! selector), PATCH (as a JSON merge patch, on the object or its `status`),
//! DELETE (honoring `preconditions`), and server-side apply on the objects it
//! holds. An apply stores the manifest sent as it is, and a dry-run apply
//! (`dryRun=All`) answers without storing.
//! Every object gets a uid and a resourceVersion when it is added, and a new
//! resourceVersion on every change. Anything else answers 404.
//!
//! [`FakeApi::after_get`] changes an object right after the next GET of it
//! is answered, which models a concurrent writer between a read and a delete.
//! [`FakeApi::on_apply`] changes what the next apply of an object stores,
//! which models a CRD's pruning or a mutating admission webhook.
//! [`FakeApi::fail_next`] answers the next requests for one path with a
//! plain-text error, as the apiserver does for a path it has not registered.
//! [`FakeApi::serve_retired_records`] adds the Activation kind under a
//! retired domain to discovery, as on a cluster that has not migrated.

use std::sync::{Arc, Mutex};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use kube::Client;
use serde_json::{Value, json};

use crate::manifest::keys;
use crate::manifest::lifecycle::RECORD_KIND;

/// `(group, version, kind, plural, namespaced)` of every kind served.
const KINDS: &[(&str, &str, &str, &str, bool)] = &[
    ("", "v1", "ConfigMap", "configmaps", true),
    ("", "v1", "Secret", "secrets", true),
    ("", "v1", "Namespace", "namespaces", false),
    (
        "rbac.authorization.k8s.io",
        "v1",
        "ClusterRole",
        "clusterroles",
        false,
    ),
    (keys::DOMAIN, "v1alpha1", RECORD_KIND, "activations", false),
    // A group served at two versions, preferred first: `Gizmo` at both,
    // `Gadget` only at the older one.
    (TWO_VERSION_GROUP, "v1", "Gizmo", "gizmos", true),
    (TWO_VERSION_GROUP, "v1beta1", "Gizmo", "gizmos", true),
    (TWO_VERSION_GROUP, "v1beta1", "Gadget", "gadgets", true),
];

/// The Activation kind under the first retired domain, which
/// [`FakeApi::serve_retired_records`] adds, as on a cluster deployed before
/// the domain moved.
const RETIRED_RECORDS: (&str, &str, &str, &str, bool) = (
    crate::legacy_domain::DOMAINS[0],
    "v1alpha1",
    RECORD_KIND,
    "activations",
    false,
);

/// The group [`KINDS`] serves at two versions. Its preferred version is
/// `v1`, the first listed.
pub(crate) const TWO_VERSION_GROUP: &str = "example.kix.test";

type Hook = Box<dyn FnOnce(&mut Value) + Send>;

#[derive(Default)]
struct State {
    objects: Vec<Value>,
    next_rv: u64,
    /// `METHOD path` of every request, in order, with `?query` when it has one.
    requests: Vec<String>,
    after_get: Vec<(String, Hook)>,
    on_apply: Vec<(String, Hook)>,
    /// `(path, remaining, status)`: answer that many requests for `path`
    /// with `status` and a plain-text body.
    failures: Vec<(String, u32, u16)>,
    /// Discovery also serves [`RETIRED_RECORDS`].
    retired_records: bool,
}

impl State {
    fn bump(&mut self) -> String {
        self.next_rv += 1;
        self.next_rv.to_string()
    }
}

/// See the module docs. Clones share one state.
#[derive(Clone, Default)]
pub struct FakeApi {
    state: Arc<Mutex<State>>,
}

impl FakeApi {
    pub fn new(objects: impl IntoIterator<Item = Value>) -> Self {
        let api = FakeApi::default();
        for o in objects {
            api.insert(o);
        }
        api
    }

    /// Add an object, assigning it a uid and a resourceVersion.
    pub(crate) fn insert(&self, mut obj: Value) {
        let mut st = self.state.lock().unwrap();
        let rv = st.bump();
        let meta = obj["metadata"].as_object_mut().expect("metadata");
        meta.insert("uid".into(), json!(format!("uid-{rv}")));
        meta.insert("resourceVersion".into(), json!(rv));
        st.objects.push(obj);
    }

    /// Run `f` on the object named `name` right after the next GET of it,
    /// and give it a new resourceVersion.
    pub fn after_get(&self, name: &str, f: impl FnOnce(&mut Value) + Send + 'static) {
        self.state
            .lock()
            .unwrap()
            .after_get
            .push((name.to_string(), Box::new(f)));
    }

    /// Run `f` on what the next apply of the object named `name` stores and
    /// answers.
    pub fn on_apply(&self, name: &str, f: impl FnOnce(&mut Value) + Send + 'static) {
        self.state
            .lock()
            .unwrap()
            .on_apply
            .push((name.to_string(), Box::new(f)));
    }

    /// Answer the next `times` requests for `path` (no query string) with
    /// `status` and a plain-text body. With 404 this is the apiserver's
    /// `404 page not found` for a path nothing serves. `u32::MAX` keeps
    /// failing.
    pub fn fail_next(&self, path: &str, times: u32, status: u16) {
        self.state
            .lock()
            .unwrap()
            .failures
            .push((path.to_string(), times, status));
    }

    /// Serve the Activation kind under a retired domain too, which is what
    /// the domain gate refuses.
    pub fn serve_retired_records(&self) {
        self.state.lock().unwrap().retired_records = true;
    }

    /// Return the sorted names of held objects of `kind`.
    pub fn names(&self, kind: &str) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let mut v: Vec<String> = st
            .objects
            .iter()
            .filter(|o| o["kind"] == kind)
            .filter_map(|o| o["metadata"]["name"].as_str().map(str::to_string))
            .collect();
        v.sort();
        v
    }

    /// Return `METHOD path` for every request seen so far, including `?query`
    /// when present.
    pub fn requests(&self) -> Vec<String> {
        self.state.lock().unwrap().requests.clone()
    }

    pub fn client(&self) -> Client {
        let api = self.clone();
        let service = tower::service_fn(move |req: http::Request<kube::client::Body>| {
            let api = api.clone();
            async move {
                let method = req.method().clone();
                let path = req.uri().path().to_string();
                let query = req.uri().query().unwrap_or("").to_string();
                // Kubernetes tells a server-side apply from a merge patch by
                // the request's content type, so the fake does too.
                let apply = req
                    .headers()
                    .get(http::header::CONTENT_TYPE)
                    .is_some_and(|v| v.as_bytes().starts_with(b"application/apply-patch"));
                let body = req.into_body().collect().await.unwrap().to_bytes();
                let (status, content_type, body) =
                    api.respond(&method, &path, &query, &body, apply);
                let resp = http::Response::builder()
                    .status(status)
                    .header("content-type", content_type)
                    .body(Full::new(Bytes::from(body)))
                    .unwrap();
                Ok::<_, std::convert::Infallible>(resp)
            }
        });
        Client::new(service, "default")
    }

    fn respond(
        &self,
        method: &http::Method,
        path: &str,
        query: &str,
        body: &[u8],
        apply: bool,
    ) -> (u16, &'static str, String) {
        {
            let mut st = self.state.lock().unwrap();
            let line = if query.is_empty() {
                format!("{method} {path}")
            } else {
                format!("{method} {path}?{query}")
            };
            st.requests.push(line);
            if let Some(f) = st
                .failures
                .iter_mut()
                .find(|(p, remaining, _)| p == path && *remaining > 0)
            {
                if f.1 != u32::MAX {
                    f.1 -= 1;
                }
                let code = f.2;
                return (code, "text/plain", format!("{code} page not found\n"));
            }
        }
        let (status, value) = self.handle(method, path, query, body, apply);
        (status, "application/json", value.to_string())
    }

    fn handle(
        &self,
        method: &http::Method,
        path: &str,
        query: &str,
        body: &[u8],
        apply: bool,
    ) -> (u16, Value) {
        let mut st = self.state.lock().unwrap();
        let mut kinds = KINDS.to_vec();
        if st.retired_records {
            kinds.push(RETIRED_RECORDS);
        }
        if let Some(doc) = discovery(&kinds, path) {
            return (200, doc);
        }
        let Some(target) = Target::parse(path) else {
            return not_found(path);
        };
        let selector = label_selector(query);
        let matches = |o: &Value| {
            target.holds(o)
                && selector
                    .iter()
                    .all(|(k, v)| o["metadata"]["labels"][k.as_str()].as_str() == Some(v.as_str()))
        };
        match (method.as_str(), &target.name) {
            ("GET", None) => {
                let items: Vec<Value> = st.objects.iter().filter(|o| matches(o)).cloned().collect();
                (
                    200,
                    json!({
                        "apiVersion": "v1",
                        "kind": format!("{}List", target.kind),
                        "metadata": { "resourceVersion": st.next_rv.to_string() },
                        "items": items,
                    }),
                )
            }
            ("GET", Some(_)) => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let answer = st.objects[i].clone();
                let name = target.name.clone().unwrap();
                if let Some(h) = st.after_get.iter().position(|(n, _)| *n == name) {
                    let (_, hook) = st.after_get.remove(h);
                    let rv = st.bump();
                    hook(&mut st.objects[i]);
                    st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
                }
                (200, answer)
            }
            ("DELETE", Some(_)) => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let options: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
                let pre = &options["preconditions"];
                let meta = &st.objects[i]["metadata"];
                let stale = ["uid", "resourceVersion"]
                    .iter()
                    .any(|k| pre[k].is_string() && pre[k] != meta[k]);
                if stale {
                    return status(409, "Conflict", "Precondition failed");
                }
                let gone = st.objects.remove(i);
                (200, gone)
            }
            ("PATCH", Some(name)) if apply => {
                let Ok(mut obj) = serde_json::from_slice::<Value>(body) else {
                    return status(400, "BadRequest", "the fake serves JSON bodies only");
                };
                let existing = st.objects.iter().position(&matches);
                let rv = st.bump();
                let uid = match existing {
                    Some(i) => st.objects[i]["metadata"]["uid"].clone(),
                    None => json!(format!("uid-{rv}")),
                };
                obj["metadata"]["uid"] = uid;
                obj["metadata"]["resourceVersion"] = json!(rv);
                if let Some(h) = st.on_apply.iter().position(|(n, _)| n == name) {
                    let (_, hook) = st.on_apply.remove(h);
                    hook(&mut obj);
                }
                if !query.split('&').any(|q| q == "dryRun=All") {
                    match existing {
                        Some(i) => st.objects[i] = obj.clone(),
                        None => st.objects.push(obj.clone()),
                    }
                }
                (if existing.is_some() { 200 } else { 201 }, obj)
            }
            ("PATCH", Some(_)) => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let patch: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
                merge_patch(&mut st.objects[i], &patch);
                let rv = st.bump();
                st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
                (200, st.objects[i].clone())
            }
            _ => status(405, "MethodNotAllowed", "not served by the fake"),
        }
    }
}

struct Target {
    kind: &'static str,
    api_version: String,
    namespaced: bool,
    namespace: Option<String>,
    name: Option<String>,
}

impl Target {
    fn parse(path: &str) -> Option<Target> {
        let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
        let (group, version, rest) = match segs.as_slice() {
            ["api", v, rest @ ..] => ("", *v, rest),
            ["apis", g, v, rest @ ..] => (*g, *v, rest),
            _ => return None,
        };
        let (namespace, plural, name) = match rest {
            ["namespaces", ns, plural, name @ ..] => (Some(ns.to_string()), *plural, name.first()),
            [plural, name @ ..] => (None, *plural, name.first()),
            _ => return None,
        };
        let &(_, _, kind, _, namespaced) = KINDS
            .iter()
            .find(|(g, v, _, p, _)| *g == group && *v == version && *p == plural)?;
        Some(Target {
            kind,
            api_version: if group.is_empty() {
                version.to_string()
            } else {
                format!("{group}/{version}")
            },
            namespaced,
            namespace,
            name: name.map(|n| n.to_string()),
        })
    }

    fn holds(&self, o: &Value) -> bool {
        let meta = &o["metadata"];
        o["kind"] == self.kind
            && o["apiVersion"] == self.api_version.as_str()
            && (!self.namespaced
                || self
                    .namespace
                    .as_deref()
                    .is_none_or(|ns| meta["namespace"] == ns))
            && self.name.as_deref().is_none_or(|n| meta["name"] == n)
    }
}

/// Apply `patch` to `target` as a JSON merge patch (RFC 7386).
fn merge_patch(target: &mut Value, patch: &Value) {
    let Value::Object(fields) = patch else {
        *target = patch.clone();
        return;
    };
    if !target.is_object() {
        *target = json!({});
    }
    let object = target.as_object_mut().expect("an object");
    for (key, value) in fields {
        if value.is_null() {
            object.remove(key);
        } else {
            merge_patch(object.entry(key.clone()).or_insert(Value::Null), value);
        }
    }
}

/// Return the discovery document at `path` for the served `kinds`.
fn discovery(kinds: &[(&str, &str, &str, &str, bool)], path: &str) -> Option<Value> {
    let resources = |group: &str, version: &str| -> Value {
        let list: Vec<Value> = kinds
            .iter()
            .filter(|(g, v, ..)| *g == group && *v == version)
            .map(|(_, _, kind, plural, namespaced)| {
                json!({
                    "name": plural,
                    "singularName": "",
                    "namespaced": namespaced,
                    "kind": kind,
                    "verbs": ["get", "list", "delete"],
                })
            })
            .collect();
        let gv = if group.is_empty() {
            version.to_string()
        } else {
            format!("{group}/{version}")
        };
        json!({ "kind": "APIResourceList", "apiVersion": "v1", "groupVersion": gv, "resources": list })
    };
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    match segs.as_slice() {
        ["api"] => Some(
            json!({ "kind": "APIVersions", "versions": ["v1"], "serverAddressByClientCIDRs": [] }),
        ),
        ["api", "v1"] => Some(resources("", "v1")),
        ["apis"] => {
            // Emit each group once with its versions in `KINDS` order. The
            // first version is preferred.
            let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
            for (g, v, ..) in kinds.iter().filter(|(g, ..)| !g.is_empty()) {
                match groups.iter_mut().find(|(name, _)| name == g) {
                    Some((_, versions)) if !versions.contains(v) => versions.push(v),
                    Some(_) => {}
                    None => groups.push((g, vec![v])),
                }
            }
            let groups: Vec<Value> = groups
                .into_iter()
                .map(|(g, versions)| {
                    let gvs: Vec<Value> = versions
                        .iter()
                        .map(|v| json!({ "groupVersion": format!("{g}/{v}"), "version": v }))
                        .collect();
                    json!({ "name": g, "versions": gvs, "preferredVersion": gvs[0] })
                })
                .collect();
            Some(json!({ "kind": "APIGroupList", "apiVersion": "v1", "groups": groups }))
        }
        ["apis", g, v] if kinds.iter().any(|(kg, kv, ..)| kg == g && kv == v) => {
            Some(resources(g, v))
        }
        _ => None,
    }
}

/// Parse `k=v` pairs from a `labelSelector` query parameter.
fn label_selector(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter_map(|kv| kv.strip_prefix("labelSelector="))
        .flat_map(|sel| {
            let decoded = sel
                .replace("%3D", "=")
                .replace("%2F", "/")
                .replace("%2C", ",");
            decoded
                .split(',')
                .filter_map(|pair| {
                    let (k, v) = pair.split_once('=')?;
                    Some((k.to_string(), v.to_string()))
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn status(code: u16, reason: &str, message: &str) -> (u16, Value) {
    (
        code,
        json!({
            "kind": "Status",
            "apiVersion": "v1",
            "metadata": {},
            "status": "Failure",
            "reason": reason,
            "message": message,
            "code": code,
        }),
    )
}

fn not_found(path: &str) -> (u16, Value) {
    status(404, "NotFound", &format!("{path} not found"))
}
