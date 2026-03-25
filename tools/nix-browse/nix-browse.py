#!/usr/bin/env python3
"""Interactive split-screen Nix/Kix store browser.

Three views, switchable with Tab and Enter/Esc:

  raw           Raw nix-store dependency tree
  kix:packages  Namespace → Package tree with cross-package dependencies
  kix:detail    Resources within a single package (Enter from packages)

Usage: nix-browse.py <store-path-or-symlink>
"""

import curses
import json
import os
import subprocess
import sys


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

    # In nix-store --graph, "A" -> "B" means B references A (A is a dep of B).
    # We want refs[B] = [...A...], so we accumulate: dependent → [dependencies].
    deps = {}   # full_path → set of full_path
    all_paths = set()

    nix_store = "/nix/store/"

    for line in out.split("\n"):
        line = line.strip()
        if "->" not in line:
            continue
        # Format: "hash-name" -> "hash-name" [color = "..."];
        parts = line.split("->", 1)
        if len(parts) != 2:
            continue
        src_base = parts[0].strip().strip('"').strip()
        dst_base = parts[1].split("[")[0].strip().strip('"').strip().rstrip(";")

        src = nix_store + src_base
        dst = nix_store + dst_base
        all_paths.add(src)
        all_paths.add(dst)

        # dst references src (src is a dep of dst)
        deps.setdefault(dst, set()).add(src)

    # Populate _ref_cache
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
        # Load the entire store graph in one subprocess call.
        # This populates _ref_cache so all subsequent get_references()
        # calls are dict lookups instead of subprocess invocations.
        status("Loading store graph...")
        bulk_load_graph(self.root_path)

        status("Finding activation...")
        self.activation_path, pi_paths = self._find_activation_and_pis()
        if not pi_paths:
            return

        # If the activation has its own graph not covered by the root's,
        # load that too (e.g. root was manifests, activation is separate).
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

            # Derive cluster name from PI labels if no Activation was found
            if self.cluster_name == "cluster":
                part_of = (meta.get("metadata", {}).get("labels", {})
                           .get("app.kubernetes.io/part-of", ""))
                if part_of:
                    self.cluster_name = part_of

        # Simultaneous BFS from all PIs to assign resource ownership.
        # Each PI seeds with its direct k8s refs. The first PI to reach
        # a resource owns it — direct refs (distance 0) always win over
        # transitive refs from another PI, so cross-package boundaries
        # are detected naturally.
        status("Walking resource graph...")
        from collections import deque
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

        # Group resources by owning package
        for res_path, pi_path in self.resource_owner.items():
            if pi_path in self.packages:
                self.packages[pi_path]["resources"].append(res_path)

        # Read all resource JSONs and build dep lists
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
        """Find the Activation path and PI store paths.

        Returns (activation_path_or_None, [pi_paths]).
        The PI list is the essential output — the Activation is nice-to-have
        for the cluster name but not required for building the model.
        """
        root = self.root_path

        # Direct: root IS the Activation JSON
        if os.path.isfile(root):
            meta = read_store_json(root)
            if meta and meta.get("kind") == "Activation":
                pis = [r for r in get_references(root) if is_k8s_path(r)]
                return root, pis

        # Dir with activation symlink (cluster-*-activation output)
        act_link = os.path.join(root, "activation")
        if os.path.exists(act_link):
            act = resolve_path(act_link)
            pis = [r for r in get_references(act) if is_k8s_path(r)]
            return act, pis

        # Scan direct refs for Activation
        for ref in get_references(root):
            if store_name(ref).startswith("k8s-Activation-"):
                pis = [r for r in get_references(ref) if is_k8s_path(r)]
                return ref, pis

        # Scan direct refs for PIs (e.g. manifests output).
        # No Activation in the graph — that's fine, we can build the model
        # from the PIs alone and derive the cluster name from labels.
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


# ── Tree model ────────────────────────────────────────────────────────

class TreeNode:
    """A node in the tree. Supports both lazy (nix) and pre-built (kix) trees."""
    __slots__ = ("path", "name", "children", "expanded", "depth",
                 "loaded", "tag", "data")

    def __init__(self, path, depth=0, tag="store", data=None):
        self.path = path
        self.name = store_name(path) if path else ""
        self.children = []
        self.depth = depth
        self.expanded = False
        self.loaded = False
        self.tag = tag
        self.data = data or {}

    def ensure_children(self):
        if self.loaded:
            return
        self.loaded = True
        if self.tag == "store" and self.path:
            refs = get_references(self.path)
            self.children = [TreeNode(r, self.depth + 1) for r in refs]

    def toggle(self):
        self.ensure_children()
        self.expanded = not self.expanded


def flatten_visible(root):
    """Flatten the tree into the currently visible rows."""
    rows = []
    def walk(node):
        rows.append(node)
        if node.expanded:
            for child in node.children:
                walk(child)
    walk(root)
    return rows


# ── Kix tree builders ─────────────────────────────────────────────────

def build_package_tree(model):
    """Build the kix:packages tree: Activation → Namespace → Package → Deps."""
    root = TreeNode(model.activation_path, depth=0, tag="activation")
    root.name = model.cluster_name
    root.loaded = True
    root.expanded = True

    for ns_name in sorted(model.namespaces):
        ns_node = TreeNode(None, depth=1, tag="namespace",
                           data={"ns": ns_name})
        ns_node.name = ns_name
        ns_node.loaded = True
        ns_node.expanded = True

        for pi_path in sorted(model.namespaces[ns_name],
                               key=lambda p: model.packages[p]["name"]):
            pkg = model.packages[pi_path]
            n_res = len(pkg["resources"])

            pi_node = TreeNode(pi_path, depth=2, tag="package",
                               data={"pi_path": pi_path})
            pi_node.name = f"{pkg['name']}  ({n_res} resources)"
            pi_node.loaded = True

            # Cross-package dep children, deduplicated by target
            by_target = {}
            for dep in model.cross_deps.get(pi_path, []):
                by_target.setdefault(dep["target_pi"], []).append(dep)

            for target_pi, edges in sorted(
                by_target.items(),
                key=lambda kv: model.packages.get(kv[0], {}).get("name", ""),
            ):
                tpkg = model.packages.get(target_pi, {})
                target_label = f"{tpkg.get('ns')}/{tpkg.get('name')}"
                edge = edges[0]
                via = f"{edge['from']} → {edge['to']}"
                if len(edges) > 1:
                    via += f" (+{len(edges) - 1})"

                dep_node = TreeNode(target_pi, depth=3, tag="dep",
                                    data={"deps": edges, "target_pi": target_pi})
                dep_node.name = f"→ {target_label}  via {via}"
                dep_node.loaded = True
                pi_node.children.append(dep_node)

            ns_node.children.append(pi_node)
        root.children.append(ns_node)

    return root


def build_detail_tree(model, pi_path):
    """Build the kix:detail tree: Package → Resource → Deps."""
    pkg = model.packages[pi_path]

    root = TreeNode(pi_path, depth=0, tag="package-root")
    root.name = f"{pkg['name']} ({pkg['ns']})"
    root.loaded = True
    root.expanded = True

    sorted_resources = sorted(
        pkg["resources"],
        key=lambda p: (
            model.resources.get(p, {}).get("kind", ""),
            model.resources.get(p, {}).get("name", ""),
        ),
    )

    for res_path in sorted_resources:
        res = model.resources.get(res_path)
        if not res:
            continue

        res_node = TreeNode(res_path, depth=1, tag="resource")
        res_node.name = f"{res['kind']}/{res['name']}"
        res_node.loaded = True

        for dep_path in sorted(res["deps"],
                                key=lambda p: model.resource_label(p)):
            dep_res = model.resources.get(dep_path)
            if not dep_res or dep_res["kind"] == "Namespace":
                continue

            dep_node = TreeNode(dep_path, depth=2, tag="resource-dep")
            dep_owner = model.resource_owner.get(dep_path)
            if dep_owner and dep_owner != pi_path:
                owner_pkg = model.packages.get(dep_owner, {})
                dep_node.name = (
                    f"→ {dep_res['kind']}/{dep_res['name']}"
                    f"  [← {owner_pkg.get('name', '?')}]"
                )
            else:
                dep_node.name = f"→ {dep_res['kind']}/{dep_res['name']}"
            dep_node.loaded = True
            res_node.children.append(dep_node)

        root.children.append(res_node)

    return root


# ── Preview logic ─────────────────────────────────────────────────────

def preview_for(path):
    """Return (lines, title) for a store path."""
    if not path or not os.path.exists(path):
        return ["(no preview)"], ""

    if os.path.isfile(path):
        return preview_file(path), os.path.basename(path)

    if os.path.isdir(path):
        entries = sorted(os.listdir(path))
        real_files = [e for e in entries if os.path.isfile(os.path.join(path, e))]
        if len(real_files) == 1:
            fp = os.path.join(path, real_files[0])
            return [f"── {real_files[0]} ──", ""] + preview_file(fp), real_files[0]
        lines = []
        for entry in entries:
            full = os.path.join(path, entry)
            if os.path.isdir(full):
                lines.append(f"  📁 {entry}/")
            elif os.path.islink(full):
                lines.append(f"  🔗 {entry} → {os.readlink(full)}")
            else:
                lines.append(f"  📄 {entry}  ({format_size(os.path.getsize(full))})")
        return lines, f"{len(entries)} entries"

    return ["(unknown path type)"], "?"


def preview_file(path):
    """Read a file and return lines, trying JSON pretty-print first."""
    try:
        size = os.path.getsize(path)
        if size > 512 * 1024:
            return [f"(file too large: {format_size(size)})"]
        with open(path, "r") as f:
            raw = f.read()
    except (OSError, UnicodeDecodeError):
        return ["(binary or unreadable file)"]
    try:
        return json.dumps(json.loads(raw), indent=2, ensure_ascii=False).split("\n")
    except (json.JSONDecodeError, ValueError):
        return raw.split("\n")


def preview_kix_activation(model):
    lines = [
        f"Cluster: {model.cluster_name}",
        f"Namespaces: {len(model.namespaces)}",
        f"Packages: {len(model.packages)}",
        f"Resources: {len(model.resources)}",
        "",
    ]
    total_cross = sum(len(d) for d in model.cross_deps.values())
    lines.append(f"Cross-package dependency edges: {total_cross}")
    lines.append("")
    for ns in sorted(model.namespaces):
        pis = model.namespaces[ns]
        names = sorted(model.packages[p]["name"] for p in pis)
        lines.append(f"  {ns}: {', '.join(names)}")
    return lines, model.cluster_name


def preview_kix_namespace(model, ns_name):
    pi_paths = model.namespaces.get(ns_name, [])
    lines = [f"Namespace: {ns_name}", f"Packages: {len(pi_paths)}", ""]
    for pi_path in sorted(pi_paths, key=lambda p: model.packages[p]["name"]):
        pkg = model.packages[pi_path]
        n_cross = len(model.cross_deps.get(pi_path, []))
        extra = f"  ({n_cross} cross-deps)" if n_cross else ""
        lines.append(f"  {pkg['name']}  ({len(pkg['resources'])} resources){extra}")
    return lines, ns_name


def preview_kix_package(model, pi_path):
    pkg = model.packages[pi_path]
    annotations = pkg["metadata"].get("metadata", {}).get("annotations", {})
    main_res = annotations.get("kix.dev/main", "")

    lines = [
        f"Package: {pkg['name']}",
        f"Namespace: {pkg['ns']}",
        f"Resources: {len(pkg['resources'])}",
    ]
    if main_res:
        lines.append(f"Main: {main_res}")
    lines.append("")

    cross = model.cross_deps.get(pi_path, [])
    if cross:
        by_target = {}
        for dep in cross:
            by_target.setdefault(dep["target_pi"], []).append(dep)
        lines.append("Dependencies:")
        for target_pi, edges in sorted(
            by_target.items(),
            key=lambda kv: model.packages.get(kv[0], {}).get("name", ""),
        ):
            tpkg = model.packages.get(target_pi, {})
            lines.append(f"  → {tpkg.get('ns')}/{tpkg.get('name')}")
            for e in edges:
                lines.append(f"      {e['from']}  →  {e['to']}")
        lines.append("")

    lines.append("Resources:")
    for r in sorted(pkg["resources"], key=lambda p: model.resource_label(p)):
        lines.append(f"  {model.resource_label(r)}")
    return lines, pkg["name"]


def preview_kix_dep(model, node_data):
    deps = node_data.get("deps", [])
    target_pi = node_data.get("target_pi")
    tpkg = model.packages.get(target_pi, {})

    lines = [
        f"Dependency: → {tpkg.get('ns')}/{tpkg.get('name')}",
        "",
        f"Edges ({len(deps)}):",
    ]
    for dep in deps:
        lines.append(f"  {dep['from']}  →  {dep['to']}")
    return lines, "dependency"


def format_size(nbytes):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if nbytes < 1024:
            return f"{nbytes:.0f} {unit}" if unit == "B" else f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TiB"


# ── View state ────────────────────────────────────────────────────────

class ViewState:
    def __init__(self, root=None):
        self.root = root
        self.cursor = 0
        self.tree_scroll = 0
        self.preview_scroll = 0


# ── TUI ───────────────────────────────────────────────────────────────

TREE_RATIO = 0.6
KEY_ENTER = (curses.KEY_ENTER, 10, 13)


def main(stdscr, root_path):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)    # selected
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_GREEN)   # title/bar
    curses.init_pair(3, curses.COLOR_YELLOW, -1)                  # search match
    curses.init_pair(4, curses.COLOR_BLACK, curses.COLOR_YELLOW)  # search input
    curses.init_pair(5, curses.COLOR_GREEN, -1)                   # package node
    curses.init_pair(6, curses.COLOR_BLUE, -1)                    # namespace node
    curses.init_pair(7, curses.COLOR_MAGENTA, -1)                 # dep node

    # ── View state ──
    nix_root = TreeNode(root_path)
    nix_root.expanded = True
    nix_root.ensure_children()

    views = {
        "raw": ViewState(nix_root),
        "kix-packages": ViewState(),
        "kix-detail": ViewState(),
    }
    mode = "raw"
    kix_model = None
    detail_pkg_name = ""

    search_query = ""
    search_mode = False

    # Preview cache: invalidated by changing (mode, node identity)
    _pcache_key = None
    _pcache = ([], "")

    def ensure_kix():
        nonlocal kix_model
        if kix_model is not None:
            return bool(kix_model.packages)

        h, w = stdscr.getmaxyx()
        def show_status(msg):
            try:
                stdscr.erase()
                stdscr.addstr(h // 2, max(0, (w - len(msg)) // 2),
                              msg, curses.color_pair(4))
                stdscr.refresh()
            except curses.error:
                pass

        kix_model = KixModel(root_path, status_fn=show_status)
        if not kix_model.packages:
            show_status("  No kix activation found in store closure  ")
            stdscr.getch()
            return False

        views["kix-packages"] = ViewState(build_package_tree(kix_model))
        return True

    def enter_detail(pi_path):
        nonlocal mode, detail_pkg_name
        pkg = kix_model.packages.get(pi_path)
        if not pkg:
            return
        detail_pkg_name = pkg["name"]
        views["kix-detail"] = ViewState(build_detail_tree(kix_model, pi_path))
        mode = "kix-detail"

    def get_preview(node):
        nonlocal _pcache_key, _pcache
        key = (mode, id(node))
        if key == _pcache_key:
            return _pcache

        if mode == "kix-packages":
            if node.tag == "activation":
                result = preview_kix_activation(kix_model)
            elif node.tag == "namespace":
                result = preview_kix_namespace(kix_model, node.data.get("ns", ""))
            elif node.tag == "package":
                result = preview_kix_package(kix_model, node.data["pi_path"])
            elif node.tag == "dep":
                result = preview_kix_dep(kix_model, node.data)
            else:
                result = (["(no preview)"], "")
        elif mode == "kix-detail":
            if node.tag == "package-root":
                result = preview_kix_package(kix_model, node.path)
            elif node.path:
                result = preview_for(node.path)
            else:
                result = (["(no preview)"], "")
        else:
            result = preview_for(node.path) if node.path else (["(no preview)"], "")

        _pcache_key = key
        _pcache = result
        return result

    # ── Main loop ──
    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        if h < 5 or w < 40:
            try:
                stdscr.addstr(0, 0, "Terminal too small")
            except curses.error:
                pass
            stdscr.refresh()
            key = stdscr.getch()
            if key == ord("q"):
                break
            continue

        tree_w = max(int(w * TREE_RATIO), 20)
        preview_w = w - tree_w - 1

        v = views[mode]
        if not v.root:
            break

        visible = flatten_visible(v.root)
        if not visible:
            break
        v.cursor = max(0, min(v.cursor, len(visible) - 1))

        # Search matches
        search_matches = set()
        if search_query:
            q = search_query.lower()
            search_matches = {i for i, n in enumerate(visible)
                              if q in n.name.lower()}

        # ── Row 0: Mode bar (left) + Preview title (right) ──
        modes_display = [("raw", "raw"), ("kix-packages", "kix:packages")]
        if mode == "kix-detail":
            modes_display.append(("kix-detail", f"kix:{detail_pkg_name}"))

        mx = 1
        for m_id, m_label in modes_display:
            if m_id == mode:
                attr = curses.color_pair(1) | curses.A_BOLD
            else:
                attr = curses.A_DIM
            text = f" {m_label} "
            try:
                stdscr.addnstr(0, mx, text, max(0, tree_w - mx), attr)
            except curses.error:
                pass
            mx += len(text) + 1

        # ── Tree pane (rows 1 .. h-2, or h-1 if no search bar) ──
        tree_y_start = 1
        has_search_bar = bool(search_mode or search_query)
        tree_y_end = h - (1 if has_search_bar else 0)
        tree_area_h = tree_y_end - tree_y_start

        # Scroll: keep cursor visible
        if v.cursor < v.tree_scroll:
            v.tree_scroll = v.cursor
        elif v.cursor >= v.tree_scroll + tree_area_h:
            v.tree_scroll = v.cursor - tree_area_h + 1

        for i in range(tree_area_h):
            row_idx = v.tree_scroll + i
            if row_idx >= len(visible):
                break

            node = visible[row_idx]
            y = tree_y_start + i
            selected = (row_idx == v.cursor)

            indent = "  " * node.depth
            node.ensure_children()
            if node.children:
                icon = "▼ " if node.expanded else "▶ "
            else:
                icon = "  "
            label = f"{indent}{icon}{node.name}"[:tree_w]

            if selected:
                attr = curses.color_pair(1) | curses.A_BOLD
            elif row_idx in search_matches:
                attr = curses.color_pair(3)
            elif node.tag in ("dep", "resource-dep"):
                attr = curses.color_pair(7)
            elif node.tag == "namespace":
                attr = curses.color_pair(6) | curses.A_BOLD
            elif node.tag == "package":
                attr = curses.color_pair(5)
            else:
                attr = curses.A_NORMAL

            try:
                stdscr.addnstr(y, 0, label, tree_w, attr)
            except curses.error:
                pass

        # ── Search bar ──
        if has_search_bar:
            sy = h - 1
            prompt = f" /{search_query}"[:tree_w]
            sattr = curses.color_pair(4) if search_mode else curses.color_pair(2)
            try:
                stdscr.addnstr(sy, 0, prompt, tree_w, sattr)
                pad = tree_w - len(prompt)
                if pad > 0:
                    stdscr.addstr(sy, len(prompt), " " * pad, sattr)
            except curses.error:
                pass

        # ── Divider ──
        for y in range(h):
            try:
                stdscr.addch(y, tree_w, "│", curses.A_DIM)
            except curses.error:
                pass

        # ── Preview pane ──
        px = tree_w + 1
        selected_node = visible[v.cursor]
        preview_lines, preview_title = get_preview(selected_node)

        # Title bar (row 0, right side)
        title_bar = f" {preview_title} " if preview_title else ""
        title_bar = title_bar[:preview_w]
        try:
            stdscr.addnstr(0, px, title_bar, preview_w,
                           curses.color_pair(2) | curses.A_BOLD)
            rem = preview_w - len(title_bar)
            if rem > 0:
                stdscr.addstr(0, px + len(title_bar), " " * (rem - 1),
                              curses.color_pair(2))
        except curses.error:
            pass

        # Content (rows 1 .. h-2)
        for i in range(1, h - 1):
            line_idx = v.preview_scroll + (i - 1)
            if line_idx >= len(preview_lines):
                break
            line = preview_lines[line_idx].replace("\t", "    ")[:preview_w - 1]
            try:
                stdscr.addnstr(i, px, line, preview_w - 1)
            except curses.error:
                pass

        # Path bar (bottom-right)
        path_str = f" {selected_node.path or selected_node.name} "
        try:
            stdscr.addnstr(h - 1, px, path_str[:preview_w], preview_w,
                           curses.color_pair(2))
            pad = preview_w - len(path_str)
            if pad > 0:
                stdscr.addstr(h - 1, px + len(path_str),
                              " " * (pad - 1), curses.color_pair(2))
        except curses.error:
            pass

        stdscr.refresh()

        # ── Input ──
        key = stdscr.getch()

        # Search mode input
        if search_mode:
            if key == 27:  # Escape
                search_mode = False
                search_query = ""
            elif key in KEY_ENTER:
                search_mode = False
                if search_matches:
                    forward = sorted(i for i in search_matches if i > v.cursor)
                    v.cursor = forward[0] if forward else min(search_matches)
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                search_query = search_query[:-1]
                if not search_query:
                    search_mode = False
            elif 32 <= key < 127:
                search_query += chr(key)
            continue

        # ── Global keys ──

        if key == ord("q"):
            break

        elif key == curses.KEY_UP or key == ord("k"):
            v.cursor = max(0, v.cursor - 1)
            v.preview_scroll = 0
            _pcache_key = None

        elif key == curses.KEY_DOWN or key == ord("j"):
            v.cursor = min(len(visible) - 1, v.cursor + 1)
            v.preview_scroll = 0
            _pcache_key = None

        elif key == ord("/"):
            search_mode = True
            search_query = ""

        elif key == ord("n"):
            if search_matches:
                forward = sorted(i for i in search_matches if i > v.cursor)
                v.cursor = forward[0] if forward else min(search_matches)

        elif key == ord("N"):
            if search_matches:
                backward = sorted(
                    (i for i in search_matches if i < v.cursor), reverse=True)
                v.cursor = backward[0] if backward else max(search_matches)

        elif key == ord("J") or key == curses.KEY_NPAGE:
            v.preview_scroll = min(
                v.preview_scroll + 10,
                max(0, len(preview_lines) - h + 2))

        elif key == ord("K") or key == curses.KEY_PPAGE:
            v.preview_scroll = max(0, v.preview_scroll - 10)

        elif key == ord("G"):
            v.cursor = len(visible) - 1
        elif key == ord("g"):
            v.cursor = 0

        elif key == ord("e"):
            node = visible[v.cursor]
            node.ensure_children()
            node.expanded = True
            for child in node.children:
                child.ensure_children()
                child.expanded = True

        elif key == ord("c"):
            for node in visible[1:]:
                node.expanded = False

        elif key == ord("y"):
            text = (visible[v.cursor].path or visible[v.cursor].name)
            for cmd in (["xclip", "-selection", "clipboard"], ["wl-copy"]):
                try:
                    subprocess.run(cmd, input=text.encode(), check=True,
                                   stderr=subprocess.DEVNULL)
                    break
                except (subprocess.CalledProcessError, FileNotFoundError):
                    continue

        # ── Mode-specific keys ──

        elif key == ord("\t"):  # Tab: switch raw ↔ kix:packages
            search_query = ""
            _pcache_key = None
            if mode == "raw":
                if ensure_kix():
                    mode = "kix-packages"
            elif mode in ("kix-packages", "kix-detail"):
                mode = "raw"

        elif key == 27:  # Escape
            if mode == "kix-detail":
                mode = "kix-packages"
                _pcache_key = None

        elif key in KEY_ENTER:
            node = visible[v.cursor]
            if mode == "kix-packages" and node.tag == "package":
                enter_detail(node.data["pi_path"])
                _pcache_key = None
            else:
                node.toggle()

        elif key == curses.KEY_RIGHT or key == ord("l"):
            node = visible[v.cursor]
            if not node.expanded:
                node.ensure_children()
                if node.children:
                    node.expanded = True

        elif key == curses.KEY_LEFT or key == ord("h"):
            node = visible[v.cursor]
            if mode == "kix-detail" and node.depth == 0:
                # At detail root: go back to packages
                mode = "kix-packages"
                _pcache_key = None
            elif node.expanded:
                node.expanded = False
            else:
                # Go to parent
                for i in range(v.cursor - 1, -1, -1):
                    if visible[i].depth < node.depth:
                        v.cursor = i
                        break


def text_mode(root_path):
    """Print kix package tree and per-package details to stdout."""
    model = KixModel(root_path, status_fn=lambda m: print(f"  {m}", file=sys.stderr))
    if not model.packages:
        print("No kix packages found.", file=sys.stderr)
        sys.exit(1)

    # Package tree
    tree = build_package_tree(model)
    # Expand packages that have dep children
    for ns_node in tree.children:
        for pkg_node in ns_node.children:
            if pkg_node.children:
                pkg_node.expanded = True

    for node in flatten_visible(tree):
        indent = "  " * node.depth
        print(f"{indent}{node.name}")

    # Per-package detail
    print()
    for ns_name in sorted(model.namespaces):
        for pi_path in sorted(model.namespaces[ns_name],
                               key=lambda p: model.packages[p]["name"]):
            pkg = model.packages[pi_path]
            detail = build_detail_tree(model, pi_path)
            # Only print packages that have deps worth showing
            has_deps = any(child.children for child in detail.children)
            if not has_deps:
                continue
            print(f"── {pkg['ns']}/{pkg['name']} ──")
            for child in detail.children:
                child.expanded = True
            for node in flatten_visible(detail):
                if node.tag == "package-root":
                    continue
                indent = "  " * (node.depth - 1)
                print(f"{indent}{node.name}")
            print()


def usage():
    print("Usage: nix-browse [--text] <store-path-or-symlink>")
    print()
    print("Modes:")
    print("  (default)       Interactive TUI browser")
    print("  --text          Print kix package tree to stdout")
    print()
    print("Views (TUI, switch with Tab):")
    print("  raw             Raw nix-store dependency tree")
    print("  kix:packages    Package tree with cross-package dependencies")
    print("  kix:detail      Resources within a package (Enter from packages)")
    print()
    print("Keybindings:")
    print("  j/k, ↑/↓       Navigate tree")
    print("  Enter           Toggle expand / Enter package detail")
    print("  h/l, ←/→       Collapse/expand (or navigate views)")
    print("  Tab             Switch raw ↔ kix:packages")
    print("  Esc             Back from kix:detail to kix:packages")
    print("  J/K, PgDn/Up    Scroll preview")
    print("  /               Search, Enter to jump, n/N next/prev")
    print("  e               Expand node + children one level")
    print("  c               Collapse all")
    print("  g/G             Jump to top/bottom")
    print("  y               Yank path to clipboard")
    print("  q               Quit")
    sys.exit(1)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    flags = [a for a in sys.argv[1:] if a.startswith("-")]

    if "-h" in flags or "--help" in flags or not args:
        usage()

    target = args[0]
    resolved = resolve_path(target)
    if not os.path.exists(resolved):
        print(f"Error: {resolved} does not exist", file=sys.stderr)
        sys.exit(1)

    if "--text" in flags:
        text_mode(resolved)
    else:
        curses.wrapper(main, resolved)
