"""Shared Kix model: Nix store graph queries and package/resource model.

Extracted from nix-browse to be reusable across tools (diff, browse, etc.).
"""

import json
import os
import subprocess
from collections import deque


# ── Store queries ─────────────────────────────────────────────────────

_ref_cache = {}


def resolve_path(path):
    """Follow symlinks to get the real store path."""
    return os.path.realpath(path)


def get_references(path):
    """Get direct references of a store path (cached, or single subprocess)."""
    if path in _ref_cache:
        return _ref_cache[path]
    try:
        out = subprocess.check_output(
            ["nix-store", "-q", "--references", path],
            stderr=subprocess.DEVNULL, text=True,
        )
        refs = [r for r in out.strip().split("\n") if r and r != path]
        refs.sort(key=lambda p: store_name(p).lower())
    except subprocess.CalledProcessError:
        refs = []
    _ref_cache[path] = refs
    return refs


def bulk_load_graph(root_path):
    """Load the entire dependency graph in one nix-store --graph call.

    Parses the dot output and populates _ref_cache for every path in the
    closure.  Returns the set of all store paths seen.
    """
    try:
        out = subprocess.check_output(
            ["nix-store", "-q", "--graph", root_path],
            stderr=subprocess.DEVNULL, text=True,
        )
    except subprocess.CalledProcessError:
        return set()

    deps = {}
    all_paths = set()
    nix_store = "/nix/store/"

    for line in out.split("\n"):
        line = line.strip()
        if "->" not in line:
            continue
        parts = line.split("->", 1)
        if len(parts) != 2:
            continue
        src_base = parts[0].strip().strip('"').strip()
        dst_base = parts[1].split("[")[0].strip().strip('"').strip().rstrip(";")
        src = nix_store + src_base
        dst = nix_store + dst_base
        all_paths.add(src)
        all_paths.add(dst)
        deps.setdefault(dst, set()).add(src)

    for path in all_paths:
        refs = sorted(deps.get(path, set()),
                      key=lambda p: store_name(p).lower())
        _ref_cache[path] = refs

    return all_paths


def store_name(path):
    """Human-readable part of a store path (after the hash-)."""
    base = os.path.basename(path)
    return base[33:] if len(base) > 33 and base[32] == "-" else base


def is_k8s_path(path):
    """Check whether a store path is a kix k8s resource."""
    return store_name(path).startswith("k8s-")


def read_store_json(path):
    """Read and parse a JSON file from a store path."""
    try:
        with open(path) as f:
            return json.loads(f.read())
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None


# ── Kix model ─────────────────────────────────────────────────────────

class KixModel:
    """Pre-computed package/resource/dependency graph from the Nix store."""

    def __init__(self, root_path, status_fn=None):
        self.root_path = root_path
        self.cluster_name = "cluster"
        self.activation_path = None

        # pi_store_path → {ns, name, store_path, resources, metadata}
        self.packages = {}
        # ns_name → [pi_store_path, ...]
        self.namespaces = {}
        # res_store_path → {kind, name, ns, store_path, deps}
        self.resources = {}
        # res_store_path → pi_store_path (owner)
        self.resource_owner = {}
        # pi_store_path → [{from, to, target_pi}, ...]
        self.cross_deps = {}

        self._load(status_fn or (lambda _: None))

    def _load(self, status):
        status("Loading store graph...")
        bulk_load_graph(self.root_path)

        status("Finding activation...")
        self.activation_path, pi_paths = self._find_activation_and_pis()
        if not pi_paths:
            return

        if self.activation_path and self.activation_path not in _ref_cache:
            bulk_load_graph(self.activation_path)

        if self.activation_path:
            act = read_store_json(self.activation_path)
            if act:
                self.cluster_name = act.get("metadata", {}).get("name", "cluster")

        status("Loading packages...")
        for pi_path in pi_paths:
            meta = read_store_json(pi_path)
            if not meta or meta.get("kind") != "PackageInstance":
                continue
            ns = meta.get("metadata", {}).get("namespace", "_cluster")
            name = meta.get("spec", {}).get("instanceName", store_name(pi_path))
            self.packages[pi_path] = {
                "ns": ns, "name": name, "store_path": pi_path,
                "resources": [], "metadata": meta,
            }
            self.namespaces.setdefault(ns, []).append(pi_path)

            if self.cluster_name == "cluster":
                part_of = (meta.get("metadata", {}).get("labels", {})
                           .get("app.kubernetes.io/part-of", ""))
                if part_of:
                    self.cluster_name = part_of

        status("Walking resource graph...")
        queue = deque()
        for pi_path in self.packages:
            for ref in get_references(pi_path):
                if is_k8s_path(ref) and ref not in self.resource_owner:
                    self.resource_owner[ref] = pi_path
                    queue.append((ref, pi_path))

        while queue:
            res_path, pi_path = queue.popleft()
            for ref in get_references(res_path):
                if is_k8s_path(ref) and ref not in self.resource_owner:
                    self.resource_owner[ref] = pi_path
                    queue.append((ref, pi_path))

        for res_path, pi_path in self.resource_owner.items():
            if pi_path in self.packages:
                self.packages[pi_path]["resources"].append(res_path)

        status("Reading resource manifests...")
        for res_path in self.resource_owner:
            meta = read_store_json(res_path)
            if not meta:
                continue
            deps = [r for r in get_references(res_path)
                    if is_k8s_path(r) and r != res_path]
            self.resources[res_path] = {
                "kind": meta.get("kind", "?"),
                "name": meta.get("metadata", {}).get("name", "?"),
                "ns": meta.get("metadata", {}).get("namespace"),
                "store_path": res_path,
                "deps": deps,
            }

        status("Computing cross-package dependencies...")
        self._compute_cross_deps()

    def _find_activation_and_pis(self):
        root = self.root_path

        if os.path.isfile(root):
            meta = read_store_json(root)
            if meta and meta.get("kind") == "Activation":
                pis = [r for r in get_references(root) if is_k8s_path(r)]
                return root, pis

        act_link = os.path.join(root, "activation")
        if os.path.exists(act_link):
            act = resolve_path(act_link)
            pis = [r for r in get_references(act) if is_k8s_path(r)]
            return act, pis

        for ref in get_references(root):
            if store_name(ref).startswith("k8s-Activation-"):
                pis = [r for r in get_references(ref) if is_k8s_path(r)]
                return ref, pis

        pi_paths = [r for r in get_references(root)
                    if store_name(r).startswith("k8s-PackageInstance-")]
        if pi_paths:
            return None, pi_paths

        return None, []

    def _compute_cross_deps(self):
        for pi_path, pkg in self.packages.items():
            deps = []
            for res_path in pkg["resources"]:
                res = self.resources.get(res_path)
                if not res:
                    continue
                for dep_path in res["deps"]:
                    dep_owner = self.resource_owner.get(dep_path)
                    if not dep_owner or dep_owner == pi_path:
                        continue
                    dep_res = self.resources.get(dep_path)
                    if not dep_res or dep_res["kind"] == "Namespace":
                        continue
                    deps.append({
                        "from": f"{res['kind']}/{res['name']}",
                        "to": f"{dep_res['kind']}/{dep_res['name']}",
                        "target_pi": dep_owner,
                    })
            self.cross_deps[pi_path] = deps

    def resource_label(self, path):
        res = self.resources.get(path)
        return f"{res['kind']}/{res['name']}" if res else store_name(path)

    # ── Convenience accessors ─────────────────────────────────────────

    def package_key(self, pi_path):
        """Return ns/name key for a package."""
        pkg = self.packages[pi_path]
        return f"{pkg['ns']}/{pkg['name']}"

    def package_version(self, pi_path):
        """Return version from PI spec, or None."""
        pkg = self.packages.get(pi_path)
        if not pkg:
            return None
        v = pkg["metadata"].get("spec", {}).get("version")
        if v and v != "<undefined>":
            return v
        return None

    def package_content_hash(self, pi_path):
        """Return content-hash annotation."""
        pkg = self.packages.get(pi_path)
        if not pkg:
            return None
        return pkg["metadata"].get("metadata", {}).get("annotations", {}).get("kix.dev/content-hash")

    def packages_by_key(self):
        """Return dict of ns/name → pi_path."""
        return {self.package_key(p): p for p in self.packages}
