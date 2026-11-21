#!/usr/bin/env python3
"""Recreate the commits base..HEAD on a new GitHub branch through the API.

    push-signed.py <owner/repo> <branch> <base-commit>
    push-signed.py --replace <owner/repo> <branch> <base-commit>

GitHub signs a commit that a GitHub App creates with the GraphQL mutation
`createCommitOnBranch`, so the branch's commits show as verified. A plain
`git push` of the agent's commits would leave them unsigned. The token comes
from `GH_TOKEN`.

With --replace, the branch already exists, such as the head of an open pull
request. The script builds the commits on a temporary branch, then moves the
branch to them, so the pull request stays open and never points at a
half-built branch.

The mutation takes file contents only, with no file modes. The script refuses
a commit that adds a file that is not a plain file or changes a file's mode,
and after the last commit it checks that GitHub's tree matches the local one.
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
GRAPHQL = os.environ.get("GITHUB_GRAPHQL_URL", f"{API}/graphql")
TOKEN = os.environ["GH_TOKEN"]

CREATE_COMMIT = """
mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid tree { oid } } }
}
"""


def fail(message):
    print(f"push-signed: {message}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def request(url, payload, method="POST"):
    req = urllib.request.Request(
        url,
        method=method,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as err:
        fail(f"{url} answered {err.code}: {err.read().decode(errors='replace')}")


# Return the additions and deletions that turn the commit's parent into it.
def file_changes(commit):
    raw = git("diff-tree", "-r", "-z", "--no-renames", "--raw", f"{commit}^", commit)
    fields = raw.split(b"\0")
    additions, deletions = [], []
    for i in range(0, len(fields) - 1, 2):
        old_mode, new_mode, _, _, status = fields[i].lstrip(b":").decode().split(" ")
        path = fields[i + 1].decode()
        if status == "D":
            deletions.append({"path": path})
            continue
        if status == "A" and new_mode != "100644":
            fail(
                f"{commit[:12]} adds {path} with mode {new_mode}; only plain files can be pushed"
            )
        if status != "A" and old_mode != new_mode:
            fail(
                f"{commit[:12]} changes the mode of {path}; the API cannot record that"
            )
        contents = git("show", f"{commit}:{path}")
        additions.append(
            {"path": path, "contents": base64.b64encode(contents).decode()}
        )
    return additions, deletions


def main():
    args = sys.argv[1:]
    replace = args[:1] == ["--replace"]
    if replace:
        args = args[1:]
    if len(args) != 3:
        fail("usage: push-signed.py [--replace] <owner/repo> <branch> <base-commit>")
    repo, target, base = args
    branch = f"{target}.refresh" if replace else target
    base = git("rev-parse", base).decode().strip()
    commits = (
        git("rev-list", "--reverse", "--no-merges", f"{base}..HEAD").decode().split()
    )
    if git("rev-list", "--merges", f"{base}..HEAD").strip():
        fail("the commits include a merge, which the API cannot recreate")
    if not commits:
        fail(f"no commits after {base}")

    # Fails when the branch exists, so a rerun never rewrites a branch a
    # person may have added to. With --replace this is the temporary branch.
    request(
        f"{API}/repos/{repo}/git/refs", {"ref": f"refs/heads/{branch}", "sha": base}
    )

    head, tree = base, None
    for commit in commits:
        additions, deletions = file_changes(commit)
        if not additions and not deletions:
            print(f"push-signed: skip {commit[:12]}, which changes no files")
            continue
        headline, _, body = (
            git("log", "-1", "--format=%B", commit).decode().partition("\n")
        )
        result = request(
            GRAPHQL,
            {
                "query": CREATE_COMMIT,
                "variables": {
                    "input": {
                        "branch": {
                            "repositoryNameWithOwner": repo,
                            "branchName": branch,
                        },
                        "message": {"headline": headline, "body": body.strip()},
                        "expectedHeadOid": head,
                        "fileChanges": {"additions": additions, "deletions": deletions},
                    }
                },
            },
        )
        if result.get("errors"):
            fail(f"creating {commit[:12]} failed: {json.dumps(result['errors'])}")
        created = result["data"]["createCommitOnBranch"]["commit"]
        head, tree = created["oid"], created["tree"]["oid"]
        print(f"push-signed: {commit[:12]} -> {head[:12]} {headline}")

    local_tree = git("rev-parse", "HEAD^{tree}").decode().strip()
    if tree != local_tree:
        fail(f"GitHub's tree {tree} differs from the local tree {local_tree}")
    if replace:
        request(
            f"{API}/repos/{repo}/git/refs/heads/{target}",
            {"sha": head, "force": True},
            "PATCH",
        )
        request(f"{API}/repos/{repo}/git/refs/heads/{branch}", None, "DELETE")
    print(
        f"push-signed: {target} is at {head}, with the same tree as the local commits"
    )


main()
