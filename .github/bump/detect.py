#!/usr/bin/env python3
"""Find packages that are behind upstream, and start a bump for each.

Usage: detect.py <packages.json> [--dispatch N]

<packages.json> is the output of
`nix eval --json .#legacyPackages.<system>.kixPackages`. The script reads
`sources.toml` next to it, finds upstream's newest release for each entry,
and writes a summary in Markdown to stdout. With `--dispatch N` it starts the
bump workflow for at most N packages.

It skips a target that the bump workflow already handled: an issue or pull
request from the bump app names it, or an earlier run for it failed. A
failed run needs a person, so the script lists it and does not start
another.

It needs GITHUB_TOKEN and GITHUB_REPOSITORY, and git on PATH.
"""

import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_TAGS = r"^v?(\d+(?:\.\d+)+)$"
BOT = "kix-run-bump[bot]"
WORKFLOW = "bump-agent.yml"
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GITHUB_TOKEN"]


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


def newest(name, entry, pinned):
    pattern = re.compile(entry.get("tags", DEFAULT_TAGS))
    skip = entry.get("skip", {})
    track = {"major": 1, "minor": 2}.get(entry.get("track"))
    tags = release_tags(entry["repo"])
    source = "releases"
    if not tags or not any(pattern.match(t) for t in tags):
        tags, source = git_tags(entry["repo"]), "tags"
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
    if not found:
        raise RuntimeError(f"no {source} matched {pattern.pattern}")
    return max(found)[1:] + (source,)


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
    dispatch = 0
    if "--dispatch" in args:
        i = args.index("--dispatch")
        dispatch = int(args[i + 1])
        del args[i : i + 2]
    versions = {
        k: v["version"] for k, v in json.loads(Path(args[0]).read_text()).items()
    }
    sources = tomllib.loads((Path(__file__).parent / "sources.toml").read_text())

    listed = {p for e in sources.values() for p in e["packages"]}
    unlisted = sorted(p for p, v in versions.items() if v and p not in listed)

    def check(item):
        name, entry = item
        try:
            pinned = pinned_version(name, entry, versions)
            target, tag, source = newest(name, entry, pinned)
            return {
                "name": name,
                "entry": entry,
                "pinned": pinned,
                "target": target,
                "tag": tag,
                "source": source,
            }
        except Exception as e:  # noqa: BLE001 - one broken source must not stop the rest
            return {"name": name, "entry": entry, "error": str(e)[:300]}

    with ThreadPoolExecutor(12) as pool:
        results = list(pool.map(check, sources.items()))

    targets, open_dirs, runs = handled()
    behind, waiting, errors = [], [], []
    for r in results:
        if "error" in r:
            errors.append(r)
            continue
        if key(r["target"]) <= key(r["pinned"]):
            continue
        dirs = [folder(p) for p in r["entry"]["packages"]]
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
                },
            },
        )
        started.append(r["name"])

    out = ["## Package bumps", ""]
    if behind:
        out += [
            "| Package | Pinned | Upstream | Step | From | Bump |",
            "|---|---|---|---|---|---|",
        ]
        for r in behind:
            mark = "started" if r["name"] in started else "not started"
            out.append(
                f"| {r['name']} | {r['pinned']} | {r['target']} (`{r['tag']}`) | {r['step']} | {r['source']} | {mark} |"
            )
    else:
        out.append("No package is behind upstream, apart from those listed below.")
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
