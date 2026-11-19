#!/usr/bin/env python3
"""Pick the bump pull requests for the combined pull request, and merge it.

    batch.py list [--push]  print what bump-batch.yml should build, as JSON
    batch.py merge  merge the combined pull request once its checks pass

Each bump has its own pull request, with the agent's report. Its checks run
once, and it is never rebased. The combined pull request on the branch
`bump/batch` carries every ready bump as one commit each, on top of main.
Its checks run once for all of them, and it merges as one. Merging it
closes the bump pull requests it carries.

A bump pull request is ready when the bump app opened it from a `bump/`
branch, it is not a draft, it has no `bump:needs-person` label, every
commit on it is from the bump app, and every check on its head passed.
A ready bump that points an image at another repository or registry is
held for a person instead. The agent reads release notes anyone can
write, so a person checks the new source.

The token comes from `GH_TOKEN`, and the repository from
`GITHUB_REPOSITORY`. The script reads pull requests through the API and
runs none of their code.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
TOKEN = os.environ["GH_TOKEN"]
REPO = os.environ["GITHUB_REPOSITORY"]
BOT = "kix-run-bump[bot]"
LABEL = "bump:needs-person"
BATCH = "bump/batch"
# Checks that run on every bump. Their presence shows that the checks list
# is not read before the workflows have started.
CORE_CHECKS = {"changelog", "change-kind", "lib-tests", "test"}
PASSED = {"success", "skipped", "neutral"}
# A changed line that names an image's repository or registry.
IMAGE_SOURCE = re.compile(r"\b(repository|registry)\b")
DIRS = re.compile(r"<!-- bump-dirs: ([^>]*) -->")
TARGET = re.compile(r"<!-- bump-target: (\S+) (\S+) -->")
PRS = re.compile(r"<!-- bump-prs: ([^>]*) -->")


def api(method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(
        f"{API}/repos/{REPO}/{path}",
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read() or "null")


def only_bot_commits(number: int) -> bool:
    commits = api("GET", f"pulls/{number}/commits?per_page=100")
    return all((c.get("author") or {}).get("login") == BOT for c in commits)


def checks_state(sha: str) -> str:
    """Return "passed", "running" or "failed" for the checks on a commit."""
    runs = api("GET", f"commits/{sha}/check-runs?per_page=100")["check_runs"]
    if not CORE_CHECKS <= {r["name"] for r in runs}:
        return "running"
    if any(r["status"] != "completed" for r in runs):
        return "running"
    if any(r["conclusion"] not in PASSED for r in runs):
        return "failed"
    return "passed"


def image_source_changes(number: int) -> list[str]:
    """Return the changed lines under kix/packages that name an image source."""
    found = []
    for f in api("GET", f"pulls/{number}/files?per_page=100"):
        if not f["filename"].startswith("kix/packages/"):
            continue
        for line in (f.get("patch") or "").splitlines():
            if line.startswith(("+++", "---")) or not line.startswith(("+", "-")):
                continue
            text = line[1:].strip()
            if text.startswith("#") or not IMAGE_SOURCE.search(text):
                continue
            found.append(f"{f['filename']}: {line}")
    return found


def comment(number: int, body: str, label: bool = True) -> None:
    api("POST", f"issues/{number}/comments", {"body": body})
    if label:
        api("POST", f"issues/{number}/labels", {"labels": [LABEL]})


def bot_prs() -> list[dict]:
    return [
        pr
        for pr in api("GET", "pulls?state=open&per_page=100")
        if pr["user"]["login"] == BOT and pr["head"]["ref"].startswith("bump/")
    ]


def batch_pr(prs: list[dict]) -> dict | None:
    return next((pr for pr in prs if pr["head"]["ref"] == BATCH), None)


def included(pr: dict) -> list[int]:
    m = PRS.search(pr["body"] or "")
    return [int(n) for n in m.group(1).split()] if m else []


def list_batch(push: bool) -> dict:
    """Return the bumps to build into the combined pull request.

    After a push to main, only an open combined pull request is built
    again. A new one starts on the schedule or by hand, so that the bumps
    the weekly check starts together go into one.
    """
    prs = bot_prs()
    batch = batch_pr(prs)
    main = api("GET", "commits/main")["sha"]
    ready, held = [], []
    for pr in prs:
        if pr["head"]["ref"] == BATCH or pr["draft"]:
            continue
        if any(label["name"] == LABEL for label in pr["labels"]):
            continue
        number = pr["number"]
        dirs = DIRS.search(pr["body"] or "")
        target = TARGET.search(pr["body"] or "")
        if not dirs or not target:
            continue
        if checks_state(pr["head"]["sha"]) != "passed":
            print(f"#{number}: checks have not passed", file=sys.stderr)
            continue
        if not only_bot_commits(number):
            print(f"#{number}: has commits from a person", file=sys.stderr)
            continue
        entry = {
            "number": number,
            "branch": pr["head"]["ref"],
            "head": pr["head"]["sha"],
            "dirs": dirs.group(1),
            "package": target.group(1),
            "target": target.group(2),
        }
        lines = image_source_changes(number)
        if lines:
            entry["lines"] = lines
            held.append(entry)
        else:
            ready.append(entry)
    ready.sort(key=lambda e: e["number"])
    numbers = [e["number"] for e in ready]
    rebuild = bool(ready) and not (push and not batch)
    if batch:
        labelled = any(label["name"] == LABEL for label in batch["labels"])
        behind = api("GET", f"compare/main...{batch['head']['sha']}")["behind_by"]
        if labelled:
            print(f"#{batch['number']}: waits for a person", file=sys.stderr)
            rebuild = False
        elif numbers == included(batch) and behind == 0:
            rebuild = False
    return {
        "main": main,
        "rebuild": rebuild,
        "prs": ready,
        "held": held,
        "batch": batch["number"] if batch else None,
    }


def merge() -> int:
    batch = batch_pr(bot_prs())
    if not batch:
        print("no combined pull request is open")
        return 0
    number = batch["number"]
    if batch["draft"] or any(label["name"] == LABEL for label in batch["labels"]):
        print(f"#{number}: waits for a person")
        return 0
    if not only_bot_commits(number):
        print(f"#{number}: has commits from a person, who merges it")
        return 0
    head = batch["head"]["sha"]
    if api("GET", f"compare/main...{head}")["behind_by"] > 0:
        print(f"#{number}: behind main, bump-batch.yml builds it again")
        return 0
    state = checks_state(head)
    if state == "running":
        print(f"#{number}: checks still running")
        return 0
    if state == "failed":
        comment(
            number,
            "A check failed on this combined pull request, so it does not merge. "
            "Each bump passed its checks on its own, so two bumps probably clash, "
            "or main changed under them. Find the bump that breaks it and label "
            f"its pull request `{LABEL}`. Then remove the label from this pull "
            "request, and the next build leaves that bump out.",
        )
        print(f"#{number}: checks failed, labelled for a person")
        return 0
    try:
        api("PUT", f"pulls/{number}/merge", {"merge_method": "merge", "sha": head})
    except urllib.error.HTTPError as e:
        # 405 or 409: main or the branch moved since the checks ran.
        print(f"#{number}: not merged, {e.code} {e.read().decode()[:200]}")
        return 0
    print(f"#{number}: merged")
    for n in included(batch):
        pr = api("GET", f"pulls/{n}")
        if pr["state"] != "open":
            continue
        api("POST", f"issues/{n}/comments", {"body": f"Merged as part of #{number}."})
        api("PATCH", f"pulls/{n}", {"state": "closed"})
        try:
            api("DELETE", f"git/refs/heads/{pr['head']['ref']}")
        except urllib.error.HTTPError:
            pass
        print(f"#{n}: closed")
    api("DELETE", f"git/refs/heads/{BATCH}")
    return 0


def main() -> int:
    if sys.argv[1:2] == ["list"] and sys.argv[2:] in ([], ["--push"]):
        print(json.dumps(list_batch(sys.argv[2:] == ["--push"])))
        return 0
    if sys.argv[1:] == ["merge"]:
        return merge()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
