//! An in-memory apiserver for tests of code that takes a `kube::Client`.
//!
//! It serves discovery for a fixed set of kinds (ConfigMap, Secret, Namespace,
//! Service, Pod, Event in two groups, CustomResourceDefinition, Deployment,
//! StatefulSet,
//! Job, ClusterRole, Kix's Activation, ActivationHead, and
//! PackageInstanceRevision, and two kinds of a group served at two
//! versions), and GET, LIST (with an equality or existence label
//! selector), PATCH (as a JSON merge patch, on the object or its `status`,
//! or as a JSON patch of `test`, `add`, `replace`, and `remove` operations,
//! refused with 422 when one fails, with `managedFields` patched as given),
//! POST (create, 409 when the name is taken), PUT (replace, honoring
//! `metadata.resourceVersion`), DELETE (honoring `preconditions` and `metadata.finalizers`), and
//! server-side apply on the objects it holds. A DELETE of an object with
//! finalizers sets its `deletionTimestamp` and keeps it, and a PATCH that
//! leaves such an object without finalizers removes it, as Kubernetes does. An apply stores the manifest sent as it is, and a dry-run apply
//! (`dryRun=All`) answers without storing. A DELETE also deletes the
//! objects that name the deleted one in `ownerReferences`, as the garbage
//! collector does. With `propagationPolicy: Foreground`, the deleted object
//! keeps the `foregroundDeletion` finalizer until every dependent with
//! `blockOwnerDeletion: true` is gone.
//! Every object gets a uid and a resourceVersion when it is added, and a new
//! resourceVersion on every change. A CustomResourceDefinition also gets
//! `metadata.generation` 1 when it is created, and one more on every PUT
//! that changes its `spec`. `/version` answers once
//! [`FakeApi::serve_version`] has set what it says. Anything else answers
//! 404.
//!
//! [`FakeApi::after_get`] changes an object right after the next GET of it
//! is answered, which models a concurrent writer between a read and a delete.
//! [`FakeApi::on_apply`] changes what the next apply of an object stores,
//! which models a CRD's pruning or a mutating admission webhook.
//! [`FakeApi::on_create`] does the same for the next create of an object.
//! [`FakeApi::fail_next`] answers the next requests for one path with a
//! plain-text error, as the apiserver does for a path it has not registered.
//! [`FakeApi::serve_retired_records`] adds the Activation kind under a
//! retired domain to discovery, as on a cluster that has not migrated.
//! [`FakeApi::serve_no_kix_kinds`] leaves Kix's own kinds out of
//! discovery, as on a cluster Kix has never deployed to.
//!
//! An apply that sends `metadata.resourceVersion` is refused with 409 when
//! the object has another one, as Kubernetes does. [`FakeApi::track_owners`]
//! turns on a small model of server-side apply's field ownership: an apply
//! owns the fields it sends, keeps the fields other managers own, removes
//! the fields it owned before and no longer sends, and is refused with 409
//! naming the other manager and the field when it would change a field
//! another manager owns, unless it is forced. Each manager has its own
//! entry, so the first apply of the same content by a second manager adds
//! an entry and changes `resourceVersion`, and an apply that changes
//! nothing, entries included, keeps `resourceVersion`. Lists count as one
//! field. [`FakeApi::update_as`] changes an object as
//! another manager's update does, taking the fields it changes.

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
    ("", "v1", "Service", "services", true),
    ("", "v1", "Pod", "pods", true),
    // Kubernetes serves Events under the core group and `events.k8s.io`.
    // Add an Event under both with one uid to model that.
    ("", "v1", "Event", "events", true),
    (
        "apiextensions.k8s.io",
        "v1",
        "CustomResourceDefinition",
        "customresourcedefinitions",
        false,
    ),
    // A second `Job` kind, in a group that `/apis` lists before `batch`, so
    // a lookup by kind alone finds it first. It is cluster-scoped, so a
    // lookup that finds the wrong one also gets the wrong scope.
    (OTHER_JOB_GROUP, "v1alpha1", "Job", "jobs", false),
    ("batch", "v1", "Job", "jobs", true),
    ("apps", "v1", "Deployment", "deployments", true),
    ("apps", "v1", "StatefulSet", "statefulsets", true),
    (
        "rbac.authorization.k8s.io",
        "v1",
        "ClusterRole",
        "clusterroles",
        false,
    ),
    (keys::DOMAIN, "v1alpha1", RECORD_KIND, "activations", false),
    (
        keys::DOMAIN,
        "v1alpha1",
        super::head::KIND,
        super::head::PLURAL,
        false,
    ),
    (
        keys::DOMAIN,
        "v1alpha1",
        super::revision::KIND,
        super::revision::PLURAL,
        false,
    ),
    ("events.k8s.io", "v1", "Event", "events", true),
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

/// A group that serves a kind named `Job`, as `batch.volcano.sh` does.
pub const OTHER_JOB_GROUP: &str = "batch.example.kix.test";

type Hook = Box<dyn FnOnce(&mut Value) + Send>;

#[derive(Default)]
struct State {
    objects: Vec<Value>,
    next_rv: u64,
    /// `METHOD path` of every request, in order, with `?query` when it has one.
    requests: Vec<String>,
    after_get: Vec<(String, Hook)>,
    on_apply: Vec<(String, Hook)>,
    on_create: Vec<(String, Hook)>,
    /// `(path, remaining, status)`: answer that many requests for `path`
    /// with `status` and a plain-text body.
    failures: Vec<(String, u32, u16)>,
    /// Discovery also serves [`RETIRED_RECORDS`].
    retired_records: bool,
    /// Discovery leaves out the kinds of [`keys::DOMAIN`].
    no_kix_kinds: bool,
    /// What `/version` answers, once set.
    version: Option<Value>,
    /// Applies keep `metadata.managedFields` ([`FakeApi::track_owners`]).
    owners: bool,
}

impl State {
    fn bump(&mut self) -> String {
        self.next_rv += 1;
        self.next_rv.to_string()
    }

    /// Remove the object at `i` when it is being deleted and has no
    /// finalizers left, then let the owners waiting for it finish.
    fn finish_deletion(&mut self, i: usize) {
        let o = &self.objects[i];
        if !o["metadata"]["deletionTimestamp"].is_null() && !has_finalizers(o) {
            self.objects.remove(i);
            self.settle();
        }
    }

    /// Delete the object with uid `uid` as the garbage collector does. In the
    /// foreground, an object that has dependents blocking its deletion keeps
    /// the `foregroundDeletion` finalizer until they are gone. Its dependents
    /// are deleted too, in the foreground when they have dependents of their
    /// own.
    fn delete_uid(&mut self, uid: &str, foreground: bool) {
        let Some(i) = self.index_of_uid(uid) else {
            return;
        };
        let dependents = self.dependents_of(uid);
        let blocked = dependents.iter().any(|(_, blocks)| *blocks);
        let meta = &mut self.objects[i]["metadata"];
        if meta["deletionTimestamp"].is_null() {
            meta["deletionTimestamp"] = json!("2026-11-24T15:54:00Z");
        }
        if foreground && blocked {
            let finalizers = meta["finalizers"].as_array().cloned().unwrap_or_default();
            if !finalizers.contains(&json!(FOREGROUND)) {
                let mut finalizers = finalizers;
                finalizers.push(json!(FOREGROUND));
                meta["finalizers"] = json!(finalizers);
            }
        }
        for (dependent, _) in dependents {
            let nested = !self.dependents_of(&dependent).is_empty();
            self.delete_uid(&dependent, foreground && nested);
        }
        if let Some(i) = self.index_of_uid(uid)
            && !has_finalizers(&self.objects[i])
        {
            self.objects.remove(i);
        }
        self.settle();
    }

    /// Remove the `foregroundDeletion` finalizer from each object whose
    /// blocking dependents are gone, and remove the objects that leaves with
    /// no finalizers.
    fn settle(&mut self) {
        loop {
            let ready = self.objects.iter().position(|o| {
                let waiting = o["metadata"]["finalizers"]
                    .as_array()
                    .is_some_and(|f| f.contains(&json!(FOREGROUND)));
                let uid = o["metadata"]["uid"].as_str().unwrap_or_default();
                waiting && !self.dependents_of(uid).iter().any(|(_, blocks)| *blocks)
            });
            let Some(i) = ready else {
                return;
            };
            let meta = &mut self.objects[i]["metadata"];
            let left: Vec<Value> = meta["finalizers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|f| **f != json!(FOREGROUND))
                .cloned()
                .collect();
            meta["finalizers"] = json!(left);
            if !has_finalizers(&self.objects[i]) {
                self.objects.remove(i);
            }
        }
    }

    fn index_of_uid(&self, uid: &str) -> Option<usize> {
        self.objects
            .iter()
            .position(|o| o["metadata"]["uid"].as_str() == Some(uid))
    }

    /// Return the uid of each object that names `uid` as an owner, and
    /// whether it blocks its owner's deletion.
    fn dependents_of(&self, uid: &str) -> Vec<(String, bool)> {
        self.objects
            .iter()
            .filter_map(|o| {
                let owner = o["metadata"]["ownerReferences"]
                    .as_array()?
                    .iter()
                    .find(|r| r["uid"].as_str() == Some(uid))?;
                Some((
                    o["metadata"]["uid"].as_str()?.to_string(),
                    owner["blockOwnerDeletion"] == json!(true),
                ))
            })
            .collect()
    }
}

/// The finalizer that holds an object deleted in the foreground until its
/// blocking dependents are gone.
const FOREGROUND: &str = "foregroundDeletion";

fn has_finalizers(o: &Value) -> bool {
    o["metadata"]["finalizers"]
        .as_array()
        .is_some_and(|f| !f.is_empty())
}

/// The `kube-system` Namespace with `uid`, which identifies the Kubernetes
/// cluster the fake stands for (`cluster::binding`).
pub fn kube_system(uid: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": { "name": "kube-system", "uid": uid },
    })
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

    /// Add an object, assigning it a resourceVersion, and a uid unless it
    /// brings one (as [`kube_system`] does).
    pub(crate) fn insert(&self, mut obj: Value) {
        let mut st = self.state.lock().unwrap();
        let rv = st.bump();
        let meta = obj["metadata"].as_object_mut().expect("metadata");
        meta.entry("uid")
            .or_insert_with(|| json!(format!("uid-{rv}")));
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

    /// Run `f` on what the next create (POST) of the object named `name`
    /// stores and answers.
    pub fn on_create(&self, name: &str, f: impl FnOnce(&mut Value) + Send + 'static) {
        self.state
            .lock()
            .unwrap()
            .on_create
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

    /// Model server-side apply's field ownership on every later apply (see
    /// the module docs).
    pub fn track_owners(&self) {
        self.state.lock().unwrap().owners = true;
    }

    /// Change the held object of `kind` named `name` with `f`, as an update
    /// by field manager `manager` through `subresource` (such as `scale`)
    /// does: the manager takes every field `f` changes from the managers that
    /// owned it, and the object gets a new resourceVersion.
    pub fn update_as(
        &self,
        manager: &str,
        subresource: Option<&str>,
        kind: &str,
        name: &str,
        f: impl FnOnce(&mut Value),
    ) {
        let mut st = self.state.lock().unwrap();
        let i = st
            .objects
            .iter()
            .position(|o| o["kind"] == kind && o["metadata"]["name"] == name)
            .expect("the object to update");
        let before = st.objects[i].clone();
        f(&mut st.objects[i]);
        let changed = changed_fields(&before, &st.objects[i]);
        owners::take(&mut st.objects[i], manager, subresource, &changed);
        let rv = st.bump();
        st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
    }

    /// Serve the Activation kind under a retired domain too, which is what
    /// the domain gate refuses.
    pub fn serve_retired_records(&self) {
        self.state.lock().unwrap().retired_records = true;
    }

    /// Leave Kix's own kinds out of discovery, as on a cluster whose
    /// CustomResourceDefinitions Kix has not installed yet.
    pub fn serve_no_kix_kinds(&self) {
        self.state.lock().unwrap().no_kix_kinds = true;
    }

    /// Answer `/version` with `git_version`, `major`, and `minor`, as the
    /// API server reports them (`"v1.31.4+k3s1"`, `"1"`, `"31"`; EKS writes
    /// `minor` as `"31+"`). Until this is called, `/version` answers 404.
    pub fn serve_version(&self, git_version: &str, major: &str, minor: &str) {
        self.state.lock().unwrap().version = Some(json!({
            "major": major,
            "minor": minor,
            "gitVersion": git_version,
            "gitCommit": "0000000000000000000000000000000000000000",
            "gitTreeState": "clean",
            "buildDate": "2026-01-01T00:00:00Z",
            "goVersion": "go1.23.0",
            "compiler": "gc",
            "platform": "linux/amd64",
        }));
    }

    /// Return the sorted names of held objects of `kind`, in any group.
    pub fn names(&self, kind: &str) -> Vec<String> {
        self.names_where(|o| o["kind"] == kind)
    }

    /// Return the sorted names of held objects of `api_version` and `kind`.
    pub fn names_of(&self, api_version: &str, kind: &str) -> Vec<String> {
        self.names_where(|o| o["apiVersion"] == api_version && o["kind"] == kind)
    }

    fn names_where(&self, keep: impl Fn(&Value) -> bool) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let mut v: Vec<String> = st
            .objects
            .iter()
            .filter(|o| keep(o))
            .filter_map(|o| o["metadata"]["name"].as_str().map(str::to_string))
            .collect();
        v.sort();
        v
    }

    /// Return a copy of the held object of `kind` named `name`, in any group.
    pub fn object(&self, kind: &str, name: &str) -> Option<Value> {
        let st = self.state.lock().unwrap();
        st.objects
            .iter()
            .find(|o| o["kind"] == kind && o["metadata"]["name"] == name)
            .cloned()
    }

    /// Change the held object of `kind` named `name` with `f`, as another
    /// writer would, giving it a new resourceVersion. An object being deleted
    /// that `f` leaves without finalizers is removed.
    pub fn patch_object(&self, kind: &str, name: &str, f: impl FnOnce(&mut Value)) {
        let mut st = self.state.lock().unwrap();
        let i = st
            .objects
            .iter()
            .position(|o| o["kind"] == kind && o["metadata"]["name"] == name)
            .expect("the object to patch");
        f(&mut st.objects[i]);
        let rv = st.bump();
        st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
        st.finish_deletion(i);
    }

    /// Remove every finalizer from the held object of `kind` named `name`, as
    /// its controller does when its cleanup is done.
    pub fn remove_finalizers(&self, kind: &str, name: &str) {
        self.patch_object(kind, name, |o| {
            o["metadata"]["finalizers"] = json!([]);
        });
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
                let content_type = req
                    .headers()
                    .get(http::header::CONTENT_TYPE)
                    .map(|v| v.as_bytes().to_vec())
                    .unwrap_or_default();
                let apply = content_type.starts_with(b"application/apply-patch");
                let json_patch = content_type.starts_with(b"application/json-patch");
                let body = req.into_body().collect().await.unwrap().to_bytes();
                let (status, content_type, body) =
                    api.respond(&method, &path, &query, &body, apply, json_patch);
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
        json_patch: bool,
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
        let (status, value) = self.handle(method, path, query, body, apply, json_patch);
        (status, "application/json", value.to_string())
    }

    fn handle(
        &self,
        method: &http::Method,
        path: &str,
        query: &str,
        body: &[u8],
        apply: bool,
        json_patch: bool,
    ) -> (u16, Value) {
        let mut st = self.state.lock().unwrap();
        if path == "/version" {
            return match &st.version {
                Some(info) => (200, info.clone()),
                None => not_found(path),
            };
        }
        let mut kinds = KINDS.to_vec();
        if st.retired_records {
            kinds.push(RETIRED_RECORDS);
        }
        if st.no_kix_kinds {
            kinds.retain(|(group, ..)| *group != keys::DOMAIN);
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
                && selector.iter().all(|(k, v)| {
                    let label = o["metadata"]["labels"][k.as_str()].as_str();
                    match v {
                        Some(v) => label == Some(v.as_str()),
                        None => label.is_some(),
                    }
                })
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
                let foreground = options["propagationPolicy"] == json!("Foreground");
                let rv = st.bump();
                st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
                let answer = st.objects[i].clone();
                let uid = answer["metadata"]["uid"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string();
                st.delete_uid(&uid, foreground);
                match st.index_of_uid(&uid) {
                    Some(i) => (200, st.objects[i].clone()),
                    None => (200, answer),
                }
            }
            ("POST", None) => {
                let Ok(mut obj) = serde_json::from_slice::<Value>(body) else {
                    return status(400, "BadRequest", "the fake serves JSON bodies only");
                };
                if !obj["metadata"]["name"].is_null()
                    && st.objects.iter().any(|o| {
                        target.holds(o) && o["metadata"]["name"] == obj["metadata"]["name"]
                    })
                {
                    return status(409, "AlreadyExists", "the object already exists");
                }
                // The apiserver marks a new CRD Established once it serves
                // the kind, which here is at once.
                if target.kind == "CustomResourceDefinition" {
                    obj["status"] = json!({
                        "conditions": [{ "type": "Established", "status": "True" }],
                    });
                    obj["metadata"]["generation"] = json!(1);
                }
                let rv = st.bump();
                let meta = &mut obj["metadata"];
                if meta["name"].is_null() {
                    let prefix = meta["generateName"].as_str().unwrap_or("").to_string();
                    meta["name"] = json!(format!("{prefix}{rv}"));
                }
                meta["uid"] = json!(format!("uid-{rv}"));
                meta["resourceVersion"] = json!(rv);
                if let Some(ns) = &target.namespace {
                    meta["namespace"] = json!(ns);
                }
                let name = meta["name"].as_str().unwrap_or_default().to_string();
                if let Some(h) = st.on_create.iter().position(|(n, _)| *n == name) {
                    let (_, hook) = st.on_create.remove(h);
                    hook(&mut obj);
                }
                st.objects.push(obj.clone());
                (201, obj)
            }
            ("PUT", Some(_)) => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let Ok(mut obj) = serde_json::from_slice::<Value>(body) else {
                    return status(400, "BadRequest", "the fake serves JSON bodies only");
                };
                let sent = &obj["metadata"]["resourceVersion"];
                if !sent.is_null() && *sent != st.objects[i]["metadata"]["resourceVersion"] {
                    return status(409, "Conflict", "the object has been modified");
                }
                let rv = st.bump();
                let stored = &st.objects[i];
                obj["metadata"]["uid"] = stored["metadata"]["uid"].clone();
                obj["metadata"]["resourceVersion"] = json!(rv);
                if target.kind == "CustomResourceDefinition" {
                    let generation = stored["metadata"]["generation"].as_i64().unwrap_or(1);
                    let moved = i64::from(obj["spec"] != stored["spec"]);
                    obj["metadata"]["generation"] = json!(generation + moved);
                }
                st.objects[i] = obj.clone();
                (200, obj)
            }
            ("PATCH", Some(name)) if apply => {
                let Ok(mut obj) = serde_json::from_slice::<Value>(body) else {
                    return status(400, "BadRequest", "the fake serves JSON bodies only");
                };
                let existing = st.objects.iter().position(&matches);
                let sent_version = obj["metadata"]["resourceVersion"].take();
                if !sent_version.is_null()
                    && existing.map(|i| &st.objects[i]["metadata"]["resourceVersion"])
                        != Some(&sent_version)
                {
                    return status(
                        409,
                        "Conflict",
                        "Operation cannot be fulfilled: the object has been modified; please apply your changes to the latest version and try again",
                    );
                }
                if st.owners {
                    let manager = query
                        .split('&')
                        .find_map(|q| q.strip_prefix("fieldManager="))
                        .unwrap_or("unknown")
                        .replace("%2F", "/");
                    let force = query.split('&').any(|q| q == "force=true");
                    match owners::apply(existing.map(|i| &st.objects[i]), &obj, &manager, force) {
                        Ok(merged) => obj = merged,
                        Err(message) => return status(409, "Conflict", &message),
                    }
                }
                if let Some(i) = existing {
                    obj["metadata"]["uid"] = st.objects[i]["metadata"]["uid"].clone();
                }
                if let Some(h) = st.on_apply.iter().position(|(n, _)| n == name) {
                    let (_, hook) = st.on_apply.remove(h);
                    hook(&mut obj);
                }
                // With ownership tracked, an apply that changes nothing,
                // its managers included, keeps the object's resourceVersion.
                let unchanged = st.owners
                    && existing.is_some_and(|i| {
                        let without_version = |o: &Value| {
                            let mut o = o.clone();
                            o["metadata"]["resourceVersion"] = Value::Null;
                            o
                        };
                        without_version(&st.objects[i]) == without_version(&obj)
                    });
                let rv = match existing {
                    Some(i) if unchanged => st.objects[i]["metadata"]["resourceVersion"].clone(),
                    _ => json!(st.bump()),
                };
                if existing.is_none() {
                    obj["metadata"]["uid"] = json!(format!("uid-{rv}"));
                }
                obj["metadata"]["resourceVersion"] = rv;
                if !query.split('&').any(|q| q == "dryRun=All") {
                    match existing {
                        Some(i) => st.objects[i] = obj.clone(),
                        None => st.objects.push(obj.clone()),
                    }
                }
                (if existing.is_some() { 200 } else { 201 }, obj)
            }
            ("PATCH", Some(_)) if json_patch => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let ops: Vec<Value> = serde_json::from_slice(body).unwrap_or_default();
                let mut patched = st.objects[i].clone();
                if let Err(message) = apply_json_patch(&mut patched, &ops) {
                    return status(422, "Invalid", &message);
                }
                let rv = st.bump();
                patched["metadata"]["resourceVersion"] = json!(rv);
                st.objects[i] = patched.clone();
                (200, patched)
            }
            ("PATCH", Some(_)) => {
                let Some(i) = st.objects.iter().position(&matches) else {
                    return not_found(path);
                };
                let patch: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
                merge_patch(&mut st.objects[i], &patch);
                let rv = st.bump();
                st.objects[i]["metadata"]["resourceVersion"] = json!(rv);
                let answer = st.objects[i].clone();
                st.finish_deletion(i);
                (200, answer)
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

/// Return the fields whose value differs between `before` and `after`.
fn changed_fields(before: &Value, after: &Value) -> Vec<Vec<String>> {
    let mut fields = owners::fields_of(before);
    for f in owners::fields_of(after) {
        if !fields.contains(&f) {
            fields.push(f);
        }
    }
    fields.retain(|f| owners::value_at(before, f) != owners::value_at(after, f));
    fields
}

/// The field ownership model of [`FakeApi::track_owners`]. A field is the
/// chain of fieldsV1 keys (`f:spec`, `f:replicas`) from the object's root
/// to a value that is not a non-empty map. Lists are one field.
mod owners {
    use serde_json::{Value, json};

    pub(super) type Field = Vec<String>;

    /// Return the fields of `obj` an apply or update can own: everything
    /// but `apiVersion`, `kind`, `status`, and the metadata other than
    /// labels and annotations.
    pub(super) fn fields_of(obj: &Value) -> Vec<Field> {
        let mut out = Vec::new();
        let Some(map) = obj.as_object() else {
            return out;
        };
        for (key, value) in map {
            match key.as_str() {
                "apiVersion" | "kind" | "status" => {}
                "metadata" => {
                    for part in ["labels", "annotations"] {
                        if let Some(sub) = value.get(part) {
                            walk(
                                sub,
                                vec!["f:metadata".into(), format!("f:{part}")],
                                &mut out,
                            );
                        }
                    }
                }
                _ => walk(value, vec![format!("f:{key}")], &mut out),
            }
        }
        out
    }

    fn walk(value: &Value, prefix: Field, out: &mut Vec<Field>) {
        match value {
            Value::Object(map) if !map.is_empty() => {
                for (key, child) in map {
                    let mut chain = prefix.clone();
                    chain.push(format!("f:{key}"));
                    walk(child, chain, out);
                }
            }
            _ => out.push(prefix),
        }
    }

    pub(super) fn value_at<'v>(obj: &'v Value, field: &[String]) -> Option<&'v Value> {
        field
            .iter()
            .try_fold(obj, |node, key| node.get(key.strip_prefix("f:")?))
    }

    fn set_at(obj: &mut Value, field: &[String], value: Value) {
        let mut node = obj;
        for key in &field[..field.len() - 1] {
            let name = key.trim_start_matches("f:");
            if !node.get(name).is_some_and(Value::is_object) {
                node[name] = json!({});
            }
            node = &mut node[name];
        }
        node[field[field.len() - 1].trim_start_matches("f:")] = value;
    }

    fn remove_at(obj: &mut Value, field: &[String]) {
        let Some((last, parents)) = field.split_last() else {
            return;
        };
        let mut node = obj;
        for key in parents {
            match node.get_mut(key.trim_start_matches("f:")) {
                Some(next) => node = next,
                None => return,
            }
        }
        if let Some(map) = node.as_object_mut() {
            map.remove(last.trim_start_matches("f:"));
        }
    }

    /// Return the fields a fieldsV1 tree names.
    fn fields_of_tree(tree: &Value, prefix: Field, out: &mut Vec<Field>) {
        let children: Vec<(&String, &Value)> = tree
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(k, _)| k.as_str() != ".")
            .collect();
        if children.is_empty() {
            if !prefix.is_empty() {
                out.push(prefix);
            }
            return;
        }
        for (key, child) in children {
            let mut chain = prefix.clone();
            chain.push(key.clone());
            fields_of_tree(child, chain, out);
        }
    }

    fn tree_of(fields: &[Field]) -> Value {
        let mut tree = json!({});
        for field in fields {
            let mut node = &mut tree;
            for key in field {
                node = node
                    .as_object_mut()
                    .expect("a fieldsV1 node")
                    .entry(key.clone())
                    .or_insert_with(|| json!({}));
            }
        }
        tree
    }

    fn entries(obj: Option<&Value>) -> Vec<Value> {
        obj.and_then(|o| o["metadata"]["managedFields"].as_array())
            .cloned()
            .unwrap_or_default()
    }

    fn fields_of_entry(entry: &Value) -> Vec<Field> {
        let mut out = Vec::new();
        fields_of_tree(&entry["fieldsV1"], Vec::new(), &mut out);
        out
    }

    fn entry(manager: &str, operation: &str, subresource: Option<&str>, fields: &[Field]) -> Value {
        let mut e = json!({
            "manager": manager,
            "operation": operation,
            "apiVersion": "v1",
            "fieldsType": "FieldsV1",
            "fieldsV1": tree_of(fields),
        });
        if let Some(sub) = subresource {
            e["subresource"] = json!(sub);
        }
        e
    }

    fn is_apply_of(e: &Value, manager: &str) -> bool {
        e["manager"] == manager && e["operation"] == "Apply" && e["subresource"].is_null()
    }

    fn path(field: &[String]) -> String {
        field
            .iter()
            .map(|k| format!(".{}", k.trim_start_matches("f:")))
            .collect()
    }

    /// Apply `sent` as field manager `manager` over `existing`, and return
    /// what the server stores, or the conflict message.
    pub(super) fn apply(
        existing: Option<&Value>,
        sent: &Value,
        manager: &str,
        force: bool,
    ) -> Result<Value, String> {
        let sent_fields = fields_of(sent);
        let all_before = entries(existing);
        let (mine, others): (Vec<Value>, Vec<Value>) = all_before
            .iter()
            .cloned()
            .partition(|e| is_apply_of(e, manager));
        let owned_before: Vec<Field> = mine.iter().flat_map(fields_of_entry).collect();
        let before = |f: &Field| existing.and_then(|o| value_at(o, f));
        let differs = |f: &Field| before(f).is_some() && before(f) != value_at(sent, f);
        if !force {
            let conflicts: Vec<String> = others
                .iter()
                .flat_map(|e| {
                    fields_of_entry(e)
                        .into_iter()
                        .filter(|f| sent_fields.contains(f) && differs(f))
                        .map(move |f| format!("conflict with {}: {}", e["manager"], path(&f)))
                })
                .collect();
            if !conflicts.is_empty() {
                return Err(format!(
                    "Apply failed with {} conflict(s): {}",
                    conflicts.len(),
                    conflicts.join(", ")
                ));
            }
        }
        let mut merged = match existing {
            Some(obj) => {
                let mut merged = obj.clone();
                let others_own: Vec<Field> = others.iter().flat_map(fields_of_entry).collect();
                for f in &owned_before {
                    if !sent_fields.contains(f) && !others_own.contains(f) {
                        remove_at(&mut merged, f);
                    }
                }
                for f in &sent_fields {
                    if let Some(v) = value_at(sent, f) {
                        set_at(&mut merged, f, v.clone());
                    }
                }
                for key in ["apiVersion", "kind"] {
                    merged[key] = sent[key].clone();
                }
                merged
            }
            None => sent.clone(),
        };
        let mut kept: Vec<Value> = Vec::new();
        for mut e in others {
            let fields: Vec<Field> = fields_of_entry(&e)
                .into_iter()
                .filter(|f| !(sent_fields.contains(f) && differs(f)))
                .collect();
            if !fields.is_empty() {
                e["fieldsV1"] = tree_of(&fields);
                kept.push(e);
            }
        }
        // An entry the manager had keeps its place, as on the API server,
        // which drops an entry that owns no field.
        let at = all_before
            .iter()
            .position(|e| is_apply_of(e, manager))
            .unwrap_or(0)
            .min(kept.len());
        if !sent_fields.is_empty() {
            kept.insert(at, entry(manager, "Apply", None, &sent_fields));
        }
        merged["metadata"]["managedFields"] = Value::Array(kept);
        Ok(merged)
    }

    /// Give `manager` the fields `changed` of `obj`, through `subresource`,
    /// taking them from every other entry.
    pub(super) fn take(
        obj: &mut Value,
        manager: &str,
        subresource: Option<&str>,
        changed: &[Field],
    ) {
        let mut out: Vec<Value> = Vec::new();
        let mut taken: Vec<Field> = changed.to_vec();
        for mut e in entries(Some(obj)) {
            let mine = e["manager"] == manager
                && e["operation"] == "Update"
                && e["subresource"].as_str() == subresource;
            let fields: Vec<Field> = fields_of_entry(&e)
                .into_iter()
                .filter(|f| !changed.contains(f))
                .collect();
            if mine {
                taken.extend(fields);
                continue;
            }
            if !fields.is_empty() {
                e["fieldsV1"] = tree_of(&fields);
                out.push(e);
            }
        }
        out.push(entry(manager, "Update", subresource, &taken));
        obj["metadata"]["managedFields"] = Value::Array(out);
    }
}

/// Apply `patch` to `target` as a JSON merge patch (RFC 7386).
/// Apply the JSON patch `ops` (RFC 6902: `test`, `add`, `replace`, and
/// `remove`) to `target`, or return why an operation failed. The API server
/// refuses a patch with any failed operation and changes nothing.
fn apply_json_patch(target: &mut Value, ops: &[Value]) -> Result<(), String> {
    fn segments(path: &str) -> Vec<String> {
        path.split('/')
            .skip(1)
            .map(|s| s.replace("~1", "/").replace("~0", "~"))
            .collect()
    }
    fn parent<'v>(target: &'v mut Value, segs: &[String]) -> Option<&'v mut Value> {
        let mut at = target;
        for s in segs {
            at = match at {
                Value::Object(m) => m.get_mut(s)?,
                Value::Array(a) => a.get_mut(s.parse::<usize>().ok()?)?,
                _ => return None,
            };
        }
        Some(at)
    }
    for op in ops {
        let path = op["path"].as_str().unwrap_or_default();
        let segs = segments(path);
        let Some((last, init)) = segs.split_last() else {
            return Err(format!("bad path {path}"));
        };
        let failed = || format!("the {} operation on {path} failed", op["op"]);
        let Some(holder) = parent(target, init) else {
            return Err(failed());
        };
        match op["op"].as_str() {
            Some("test") => {
                let found = match holder {
                    Value::Object(m) => m.get(last),
                    Value::Array(a) => last.parse::<usize>().ok().and_then(|i| a.get(i)),
                    _ => None,
                };
                if found != Some(&op["value"]) {
                    return Err(format!("testing value {path} failed"));
                }
            }
            Some("add" | "replace") => match holder {
                Value::Object(m) => {
                    if op["op"] == "replace" && !m.contains_key(last) {
                        return Err(failed());
                    }
                    m.insert(last.clone(), op["value"].clone());
                }
                Value::Array(a) => {
                    let i = last.parse::<usize>().map_err(|_| failed())?;
                    if i >= a.len() {
                        return Err(failed());
                    }
                    a[i] = op["value"].clone();
                }
                _ => return Err(failed()),
            },
            Some("remove") => match holder {
                Value::Object(m) => {
                    m.remove(last).ok_or_else(failed)?;
                }
                Value::Array(a) => {
                    let i = last.parse::<usize>().map_err(|_| failed())?;
                    if i >= a.len() {
                        return Err(failed());
                    }
                    a.remove(i);
                }
                _ => return Err(failed()),
            },
            _ => return Err(failed()),
        }
    }
    Ok(())
}

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

/// Parse the terms of a `labelSelector` query parameter: `k=v` requires the
/// value, a bare `k` requires the label to exist.
fn label_selector(query: &str) -> Vec<(String, Option<String>)> {
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
                .filter(|term| !term.is_empty())
                .map(|term| match term.split_once('=') {
                    Some((k, v)) => (k.to_string(), Some(v.to_string())),
                    None => (term.to_string(), None),
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

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::{Api, DynamicObject, Patch, PatchParams};
    use kube::discovery::ApiResource;

    fn config_maps(api: &FakeApi) -> Api<DynamicObject> {
        let ar = ApiResource {
            group: String::new(),
            version: "v1".into(),
            api_version: "v1".into(),
            kind: "ConfigMap".into(),
            plural: "configmaps".into(),
        };
        Api::namespaced_with(api.client(), "app", &ar)
    }

    fn config_map(value: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "shared", "namespace": "app" },
            "data": { "key": value },
        })
    }

    async fn apply(
        api: &Api<DynamicObject>,
        manager: &str,
        value: &str,
        force: bool,
    ) -> Result<DynamicObject, kube::Error> {
        let mut params = PatchParams::apply(manager);
        if force {
            params = params.force();
        }
        api.patch("shared", &params, &Patch::Apply(config_map(value)))
            .await
    }

    fn managers(obj: &DynamicObject) -> Vec<String> {
        obj.metadata
            .managed_fields
            .iter()
            .flatten()
            .filter_map(|e| e.manager.clone())
            .collect()
    }

    /// The model the tests of two Kix clusters rely on, as kind showed it:
    /// the same content applied again by the same manager changes nothing.
    /// The first apply of it by a second manager adds an entry and changes
    /// `resourceVersion` once. A different value from the second manager is
    /// refused, naming the first manager and the field, unless forced.
    #[tokio::test]
    async fn each_manager_has_its_own_entry() {
        let fake = FakeApi::new(Vec::<Value>::new());
        fake.track_owners();
        let api = config_maps(&fake);
        let first = apply(&api, "kix/a", "1", false).await.unwrap();
        let again = apply(&api, "kix/a", "1", false).await.unwrap();
        assert_eq!(
            again.metadata.resource_version,
            first.metadata.resource_version
        );
        assert_eq!(managers(&again), ["kix/a"]);

        let second = apply(&api, "kix/b", "1", false).await.unwrap();
        assert_ne!(
            second.metadata.resource_version,
            first.metadata.resource_version
        );
        assert_eq!(managers(&second), ["kix/b", "kix/a"]);
        let both = apply(&api, "kix/a", "1", false).await.unwrap();
        assert_eq!(
            both.metadata.resource_version,
            second.metadata.resource_version
        );

        let refused = apply(&api, "kix/b", "2", false).await.unwrap_err();
        let kube::Error::Api(status) = refused else {
            panic!("{refused}");
        };
        assert_eq!(status.code, 409);
        assert!(
            status
                .message
                .contains("conflict with \"kix/a\": .data.key"),
            "{}",
            status.message
        );
        let forced = apply(&api, "kix/b", "2", true).await.unwrap();
        assert_eq!(managers(&forced), ["kix/b"]);
    }
}
