#!/usr/bin/env python3
"""Find packages that are behind upstream, and start a bump for each.

Usage: detect.py <packages.json> [--dispatch N]
       detect.py --pinned <name> <packages.json>

<packages.json> is the output of
`nix eval --json .#legacyPackages.<system>.kixPackages`. The script reads
`sources.toml` next to it and lists upstream's releases for each entry. The
target of a bump is the newest release whose images the registry has
(`readiness.py`), so a release that is tagged before its images are
published waits, and an older release that is published is taken
meanwhile. The script writes a summary in Markdown to stdout. With
`--dispatch N` it starts the bump workflow for at most N packages.

It skips a target that the bump workflow already handled: an issue or pull
request from the bump app names it, or an earlier run for it failed. A
failed run needs a person, so the script lists it and does not start
another.

`--pinned` prints the version the named entry pins and does nothing else.

It needs GITHUB_TOKEN and GITHUB_REPOSITORY, and git, nix, and crane on PATH.
"""

import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import readiness

DEFAULT_TAGS = r"^v?(\d+(?:\.\d+)+)$"
BOT = "kix-run-bump[bot]"
WORKFLOW = "bump-agent.yml"
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ.get("GITHUB_REPOSITORY")
TOKEN = os.environ.get("GITHUB_TOKEN")

IMAGES_EXPR = """
let
  lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib;
in
import ./kix/packages/release-images.nix { inherit lib; }
  (builtins.fromJSON (builtins.readFile %s))
"""


def api(path, data=None):
    url = path if path.startswith("https://") else f"{API}/{path}"
    req = urllib.request.Request(
        url,
        data=None if data is None else json.dumps(data).encode(),
        method="GET" if data is None else "POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
        },
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            # GitHub answers a slow listing with 502 or 504 now and then.
            if e.code < 500 or attempt == 2:
                raise


def pages(path, limit=10, size=100):
    sep = "&" if "?" in path else "?"
    for n in range(1, limit + 1):
        got = api(f"{path}{sep}per_page={size}&page={n}")
        if isinstance(got, dict):
            got = next(v for v in got.values() if isinstance(v, list))
        yield from got
        if len(got) < size:
            return


def key(version):
    return tuple(int(x) for x in version.split("."))


def step(pinned, target):
    a, b = key(pinned), key(target)
    if b[0] != a[0] or (a[0] == 0 and b[1:2] != a[1:2]):
        return "major"
    return "minor" if b[1:2] != a[1:2] else "patch"


def release_tags(repo):
    """Return the tags of a GitHub project's releases, or None when it has none."""
    m = re.match(r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$", repo)
    if not m:
        return None
    # A page of 100 releases with their notes can take GitHub longer than its
    # gateway allows.
    releases = list(pages(f"repos/{m[1]}/{m[2]}/releases", limit=6, size=50))
    if not releases:
        return None
    return [r["tag_name"] for r in releases if not r["draft"] and not r["prerelease"]]


def git_tags(repo):
    out = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", repo],
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    ).stdout
    return [line.split("refs/tags/", 1)[1] for line in out.splitlines()]


def matching(tags, entry, pinned):
    """Return the releases among `tags` as (version, tag), newest first.

    A tag counts when the entry's pattern matches it, its version is not in
    `skip`, and it is on the line `track` names.
    """
    pattern = re.compile(entry.get("tags", DEFAULT_TAGS))
    skip = entry.get("skip", {})
    track = {"major": 1, "minor": 2}.get(entry.get("track"))
    found = []
    for tag in tags:
        m = pattern.match(tag)
        if not m:
            continue
        version = m[1].replace("_", ".")
        if version in skip or len(version.split(".")) < 2:
            continue
        if track and key(version)[:track] != key(pinned)[:track]:
            continue
        found.append((key(version), version, tag))
    return [f[1:] for f in sorted(found, reverse=True)]


def candidates(entry, pinned):
    """Return upstream's releases as (version, tag), newest first, and where they came from."""
    pattern = re.compile(entry.get("tags", DEFAULT_TAGS))
    tags = release_tags(entry["repo"])
    source = "releases"
    if not tags or not any(pattern.match(t) for t in tags):
        tags, source = git_tags(entry["repo"]), "tags"
    found = matching(tags, entry, pinned)
    if not found:
        raise RuntimeError(f"no {source} matched {pattern.pattern}")
    return found, source


def in_reach(newer, pinned, through):
    """Return the versions of `newer` that upstream supports moving to from `pinned`.

    With `through = "minor"`, that is the patches of the pinned minor
    version while it has any newer than `pinned`, and the patches of the
    next minor version after that.
    """
    if through is None or not newer:
        return newer
    if through != "minor":
        raise RuntimeError(f'through = "{through}" is not supported. Use "minor".')

    def line(version):
        return key(version)[:2]

    lines = {line(v) for v, _ in newer}
    wanted = line(pinned) if line(pinned) in lines else min(lines)
    return [(v, t) for v, t in newer if line(v) == wanted]


def release_images(wanted):
    """Return the images each package would pin at each version in `wanted`.

    `wanted` maps a package name to `{"from": pinned, "to": [versions]}`.
    """
    if not wanted:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump(wanted, f)
        f.flush()
        out = subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", IMAGES_EXPR % f.name],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    return json.loads(out)


def pick(newer, images, look=readiness.problem, need=readiness.needed):
    """Return the newest version of `newer` that is ready, and why each newer one is not.

    `images` maps a version to the images of that release, each with the
    `ref` to ask for and the reference it `replaces`. A release with no such
    image cannot be checked here, so it counts as ready. Raises
    readiness.CouldNotCheck when a registry did not answer, because an older
    release must not be taken while nothing is known about a newer one.
    """
    needs = {}
    not_ready = []
    for version, tag in newer:
        why = None
        for image in images.get(version, []):
            if image["replaces"] not in needs:
                needs[image["replaces"]] = need(image["replaces"])
            found = look(image["ref"], needs[image["replaces"]])
            if found:
                why = f"`{image['ref']}`: {found}"
                break
        if why is None:
            return (version, tag), not_ready
        not_ready.append((version, why))
    return None, not_ready


def pinned_version(name, entry, versions):
    if "pinned" in entry:
        spec = entry["pinned"]
        m = re.search(spec["match"], Path(spec["file"]).read_text())
        if not m:
            raise RuntimeError(f"{spec['match']} matches nothing in {spec['file']}")
        return m[1]
    found = {versions.get(p) for p in entry["packages"]}
    if None in found:
        missing = [p for p in entry["packages"] if versions.get(p) is None]
        raise RuntimeError(f"no meta.version for {', '.join(missing)}")
    if len(found) > 1:
        raise RuntimeError(
            f"the packages pin different versions: {', '.join(sorted(found))}"
        )
    return found.pop().removeprefix("v")


def folder(package):
    level, _, name = package.rpartition(".")
    return f"kix/packages/{level or 'stable'}/{name}"


def handled():
    """Return the targets the bump workflow already acted on, and the folders in flight."""
    targets, open_dirs = set(), set()
    creator = urllib.parse.quote(BOT)
    for item in pages(f"repos/{REPO}/issues?state=all&creator={creator}"):
        body = item.get("body") or ""
        if m := re.search(r"<!-- bump-target: (\S+) (\S+) -->", body):
            targets.add((m[1], m[2]))
        if item["state"] == "open" and (
            m := re.search(r"<!-- bump-dirs: ([^>]*) -->", body)
        ):
            open_dirs.update(m[1].split())
    runs = {}
    for run in pages(f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs", limit=3):
        if m := re.match(r"^Bump (\S+) to (\S+)$", run.get("display_title") or ""):
            state = run["status"] if run["status"] != "completed" else run["conclusion"]
            runs.setdefault((m[1], m[2]), set()).add(state)
    return targets, open_dirs, runs


def main():
    args = sys.argv[1:]
    sources = tomllib.loads((Path(__file__).parent / "sources.toml").read_text())
    if args[:1] == ["--pinned"]:
        versions = {
            k: v["version"] for k, v in json.loads(Path(args[2]).read_text()).items()
        }
        print(pinned_version(args[1], sources[args[1]], versions))
        return 0
    dispatch = 0
    if "--dispatch" in args:
        i = args.index("--dispatch")
        dispatch = int(args[i + 1])
        del args[i : i + 2]
    versions = {
        k: v["version"] for k, v in json.loads(Path(args[0]).read_text()).items()
    }

    listed = {p for e in sources.values() for p in e["packages"]}
    unlisted = sorted(p for p, v in versions.items() if v and p not in listed)

    def check(item):
        name, entry = item
        try:
            pinned = pinned_version(name, entry, versions)
            found, source = candidates(entry, pinned)
            newer = [(v, t) for v, t in found if key(v) > key(pinned)]
            return {
                "name": name,
                "entry": entry,
                "pinned": pinned,
                "newer": in_reach(newer, pinned, entry.get("through")),
                "source": source,
            }
        except Exception as e:  # noqa: BLE001 - one broken source must not stop the rest
            return {"name": name, "entry": entry, "error": str(e)[:300]}

    with ThreadPoolExecutor(12) as pool:
        results = list(pool.map(check, sources.items()))

    images = release_images(
        {
            package: {"from": r["pinned"], "to": [v for v, _ in r["newer"]]}
            for r in results
            if r.get("newer")
            for package in r["entry"]["packages"] + r["entry"].get("also", [])
        }
    )

    def choose(r):
        packages = r["entry"]["packages"] + r["entry"].get("also", [])
        by_version = {
            v: [i for p in packages for i in images.get(p, {}).get(v, [])]
            for v, _ in r["newer"]
        }
        r["checked"] = any(by_version.values())
        try:
            r["found"], r["not_ready"] = pick(r["newer"], by_version)
        except readiness.CouldNotCheck as e:
            r["error"] = f"a registry did not answer: {str(e)[:300]}"

    with ThreadPoolExecutor(12) as pool:
        list(pool.map(choose, [r for r in results if r.get("newer")]))

    targets, open_dirs, runs = handled()
    behind, waiting, errors, not_ready, unchecked = [], [], [], [], []
    for r in results:
        if "error" in r:
            errors.append(r)
            continue
        if not r["newer"]:
            continue
        not_ready += [(r, version, why) for version, why in r["not_ready"]]
        if r["found"] is None:
            continue
        r["target"], r["tag"] = r["found"]
        if not r["checked"]:
            unchecked.append(r["name"])
        dirs = [folder(p) for p in r["entry"]["packages"] + r["entry"].get("also", [])]
        states = runs.get((r["name"], r["target"]), set())
        if (r["name"], r["target"]) in targets:
            r["why"] = "an issue or pull request from the bump app names this version"
        elif open_dirs & set(dirs):
            r["why"] = (
                "an open issue or pull request from the bump app covers this package"
            )
        elif states & {"queued", "in_progress", "waiting", "pending", "requested"}:
            r["why"] = "a bump run for this version is running"
        elif states & {"failure", "timed_out", "startup_failure"}:
            r["why"] = (
                "a bump run for this version failed, so a person must start the next one"
            )
        if "why" in r:
            waiting.append(r)
        else:
            r["dirs"] = dirs
            r["step"] = step(r["pinned"], r["target"])
            behind.append(r)

    order = {"patch": 0, "minor": 1, "major": 2}
    behind.sort(key=lambda r: (order[r["step"]], r["name"]))
    started = []
    for r in behind[:dispatch]:
        api(
            f"repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
            {
                "ref": "main",
                "inputs": {
                    "package": r["name"],
                    "dirs": " ".join(r["dirs"]),
                    "pinned": r["pinned"],
                    "target": r["target"],
                    "tag": r["tag"],
                    "git": r["entry"]["repo"],
                    "newer": " ".join(v for v, _ in r["not_ready"]),
                },
            },
        )
        started.append(r["name"])

    out = ["## Package bumps", ""]
    if behind:
        out += [
            "| Package | Pinned | Target | Step | From | Bump |",
            "|---|---|---|---|---|---|",
        ]
        for r in behind:
            mark = "started" if r["name"] in started else "not started"
            out.append(
                f"| {r['name']} | {r['pinned']} | {r['target']} (`{r['tag']}`) | {r['step']} | {r['source']} | {mark} |"
            )
    else:
        out.append("No package has a bump to start, apart from those listed below.")
    if unchecked:
        out += [
            "",
            "No image of these packages names the version, so their targets "
            f"were not checked against a registry: {', '.join(sorted(unchecked))}.",
        ]
    if not_ready:
        out += ["", "### Released, and not ready", ""]
        out += [
            "Each of these is newer than the target above, or than the pinned "
            "version when the package has no target. A bump starts once the "
            "registry has every image of the release.",
            "",
        ]
        out += [f"- {r['name']} {version}: {why}." for r, version, why in not_ready]
    if waiting:
        out += ["", "### Behind, and waiting on earlier work", ""]
        out += [
            f"- {r['name']} {r['pinned']} to {r['target']}: {r['why']}."
            for r in waiting
        ]
    if errors:
        out += ["", "### Could not check", ""]
        out += [f"- {r['name']}: {r['error']}" for r in errors]
    if unlisted:
        out += ["", "### Not in sources.toml", ""]
        out.append(
            "These packages set `meta.version` and name no upstream in `.github/bump/sources.toml`:"
        )
        out.append("")
        out += [f"- {p}" for p in unlisted]
    print("\n".join(out))
    return 1 if errors or unlisted else 0


if __name__ == "__main__":
    sys.exit(main())
