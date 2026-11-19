#!/usr/bin/env python3
"""Merge the bump app's upgrade pull requests whose checks all passed.

    merge.py

A pull request merges when all of these hold:

- the bump app opened it from a `bump/` branch, it is not a draft, and it
  has no `bump:needs-person` label. Only an `upgraded` outcome opens one
  like that.
- every commit on it is from the bump app. A person who pushes to the
  branch merges it themselves.
- it is up to date with main. `bump-refresh.yml` rebases one that is
  behind, and its checks run again.
- every check on its head commit finished and passed, and the core checks
  are among them.
- it points no image at another repository or registry. The agent reads
  release notes anyone can write, so such a change goes to a person. The
  script labels the pull request `bump:needs-person` and says why.

The token comes from `GH_TOKEN`, and the repository from `GITHUB_REPOSITORY`. The script reads the pull request through
the API and runs none of its code.
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
# Checks that run on every bump. Their presence shows that the checks list
# is not read before the workflows have started.
CORE_CHECKS = {"changelog", "change-kind", "lib-tests", "test"}
PASSED = {"success", "skipped", "neutral"}
# A changed line that names an image's repository or registry.
IMAGE_SOURCE = re.compile(r"\b(repository|registry)\b")


def api(method: str, path: str, body: dict | None = None):
    url = path if path.startswith("http") else f"{API}/repos/{REPO}/{path}"
    req = urllib.request.Request(
        url,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read() or "null")


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


def check(pr: dict) -> str | None:
    """Return why the pull request cannot merge yet, or None when it can."""
    number = pr["number"]
    if pr["draft"] or any(label["name"] == LABEL for label in pr["labels"]):
        return "it is not an upgrade"
    commits = api("GET", f"pulls/{number}/commits?per_page=100")
    if any((c.get("author") or {}).get("login") != BOT for c in commits):
        return "it has commits from someone other than the bump app"
    head = pr["head"]["sha"]
    if api("GET", f"compare/main...{head}")["behind_by"] > 0:
        return "it is behind main"
    runs = api("GET", f"commits/{head}/check-runs?per_page=100")["check_runs"]
    missing = CORE_CHECKS - {r["name"] for r in runs}
    if missing:
        return f"checks have not started: {', '.join(sorted(missing))}"
    pending = sorted(r["name"] for r in runs if r["status"] != "completed")
    if pending:
        return f"checks still running: {', '.join(pending)}"
    failed = sorted(r["name"] for r in runs if r["conclusion"] not in PASSED)
    if failed:
        return f"checks failed: {', '.join(failed)}"
    return None


def hold(number: int, lines: list[str]) -> None:
    shown = "\n".join(lines[:20])
    body = (
        "This bump changes where an image comes from, so it does not merge on "
        "its own. The agent reads upstream release notes, and anyone can write "
        "text there. Check that the new source belongs to the upstream project, "
        "then merge this yourself.\n\n"
        f"The changed lines:\n\n```\n{shown}\n```"
    )
    api("POST", f"issues/{number}/comments", {"body": body})
    api("POST", f"issues/{number}/labels", {"labels": [LABEL]})


def main() -> int:
    for pr in api("GET", "pulls?state=open&per_page=100"):
        if pr["user"]["login"] != BOT or not pr["head"]["ref"].startswith("bump/"):
            continue
        number = pr["number"]
        reason = check(pr)
        if reason:
            print(f"#{number}: waits, {reason}")
            continue
        lines = image_source_changes(number)
        if lines:
            hold(number, lines)
            print(f"#{number}: held for a person, it changes an image source")
            continue
        try:
            api(
                "PUT",
                f"pulls/{number}/merge",
                {"merge_method": "merge", "sha": pr["head"]["sha"]},
            )
        except urllib.error.HTTPError as e:
            # 405 or 409: main or the branch moved since the checks ran. The
            # next run tries again.
            print(f"#{number}: not merged, {e.code} {e.read().decode()[:200]}")
            continue
        print(f"#{number}: merged")
        # Merging moves main, so the other pull requests are now behind. The
        # refresh workflow rebases them, and their checks start this again.
        break
    return 0


if __name__ == "__main__":
    sys.exit(main())
