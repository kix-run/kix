"""Shared routines for vendoring upstream CRDs and operator RBAC into kix
packages.

`scripts/vendor-crds.py` is the driver. A package's `crds/update.py` (the
escape hatch for an upstream that is not a public URL) imports from here so
there is one copy of fetch, parse and render. See
v2_discussions/146_crd_vendoring_and_upgrades.md.
"""

from __future__ import annotations

import json
import pathlib
import re
import time
import urllib.error
import urllib.request

import yaml

USER_AGENT = "kixpkgs-vendor-crds (+https://github.com/kix-run/kixpkgs)"
CRD_KIND = "CustomResourceDefinition"
RBAC_KINDS = ("ClusterRole", "Role")


class VendorError(Exception):
    """A problem with one package's sources; reported, never a traceback."""


def fetch(url: str, *, timeout: float = 30.0, attempts: int = 3) -> bytes:
    """GET a public URL. Retries transient failures with a short backoff."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code < 500 and error.code != 429:
                raise VendorError(f"{url}: HTTP {error.code}") from error
            last = error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last = error
        time.sleep(1.5 * (attempt + 1))
    raise VendorError(f"{url}: {last}")


def documents_in(text: bytes | str, source: str) -> list[dict]:
    """The mapping documents of a YAML stream; empty documents are dropped."""
    if isinstance(text, bytes):
        text = text.decode("utf-8")
    try:
        documents = list(yaml.safe_load_all(text))
    except yaml.YAMLError as error:
        raise VendorError(f"{source}: not YAML: {error}") from error
    return [d for d in documents if isinstance(d, dict)]


def crds_in(text: bytes | str, *, source: str = "<input>") -> list[dict]:
    """Every CustomResourceDefinition document in a YAML stream.

    Other kinds (an operator bundle carries Deployments and RBAC alongside
    its CRDs) are ignored, so a whole upstream manifest is a valid source.
    """
    found = [d for d in documents_in(text, source) if d.get("kind") == CRD_KIND]
    for crd in found:
        name = crd.get("metadata", {}).get("name")
        if not name:
            raise VendorError(
                f"{source}: a CustomResourceDefinition has no metadata.name"
            )
        strategy = crd.get("spec", {}).get("conversion", {}).get("strategy")
        if strategy == "Webhook":
            # Doc 146 §8: the webhook names a Service the package would have
            # to create under its own naming. Refused until that is designed.
            raise VendorError(
                f"{source}: {name} carries a conversion webhook, which kix does not "
                "vendor yet (v2_discussions/146 §8)"
            )
    return found


def fetch_crds(url: str, only: set[str] | None = None) -> list[dict]:
    """The CRDs at a public URL, optionally restricted to the named ones."""
    found = crds_in(fetch(url), source=url)
    if not only:
        return found
    by_name = {c["metadata"]["name"]: c for c in found}
    missing = sorted(only - by_name.keys())
    if missing:
        raise VendorError(f"{url}: does not contain {', '.join(missing)}")
    return [by_name[name] for name in sorted(only)]


def roles_in(
    text: bytes | str, selectors: set[str], *, source: str = "<input>"
) -> list[dict]:
    """The ClusterRoles and Roles in a YAML stream that `selectors` name,
    each as `Kind/name`, sorted by selector. Every selector must match a
    document; selecting any other kind is refused, because a package builds
    its own bindings and service accounts."""
    for selector in sorted(selectors):
        kind, _, name = selector.partition("/")
        if not name:
            raise VendorError(f"{source}: {selector} is not Kind/name")
        if kind not in RBAC_KINDS:
            raise VendorError(
                f"{source}: {selector}: only {' and '.join(RBAC_KINDS)} are vendored"
            )

    def selector_of(doc: dict) -> str:
        return f"{doc.get('kind')}/{doc.get('metadata', {}).get('name')}"

    by_selector = {
        selector_of(d): d
        for d in documents_in(text, source)
        if selector_of(d) in selectors
    }
    missing = sorted(selectors - by_selector.keys())
    if missing:
        raise VendorError(f"{source}: does not contain {', '.join(missing)}")
    return [by_selector[s] for s in sorted(selectors)]


def fetch_roles(url: str, selectors: set[str]) -> list[dict]:
    """The roles a `rbac/sources.txt` line names. A URL without selectors is
    refused: an operator bundle holds roles for several service accounts."""
    if not selectors:
        raise VendorError(f"{url}: name the roles to take from it, as Kind/name")
    return roles_in(fetch(url), selectors, source=url)


def render(crd: dict) -> str:
    """What gets committed: the whole upstream object, sorted, so a refresh
    diff reads as what moved upstream."""
    return json.dumps(crd, indent=2, sort_keys=True) + "\n"


def file_name(crd: dict) -> str:
    return f"{crd['metadata']['name']}.json"


def rbac_file_name(role: dict) -> str:
    """`<kind>-<name>.json`, with `:` in the name written as `_`
    (`kubevirt.io:operator` gives `clusterrole-kubevirt.io_operator.json`).
    Any other character outside `[a-z0-9.-]` is refused."""
    name = role["metadata"]["name"]
    if not re.fullmatch(r"[a-z0-9.:-]+", name):
        raise VendorError(
            f"{role['kind']}/{name}: the name has a character outside [a-z0-9.:-], "
            "which no file name mapping covers"
        )
    return f"{role['kind'].lower()}-{name.replace(':', '_')}.json"


def parse_sources(path: pathlib.Path) -> list[tuple[str, set[str]]]:
    """`sources.txt`: one public URL per line, optionally followed by the
    names of the objects to take from it (CRD names under `crds/`,
    `Kind/name` under `rbac/`). Blank lines and `#` comments are ignored. A
    URL with no names contributes every CRD it holds."""
    entries: list[tuple[str, set[str]]] = []
    for line_number, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        url, *names = line.split()
        if "://" not in url:
            raise VendorError(f"{path}:{line_number}: not a URL: {url}")
        entries.append((url, set(names)))
    if not entries:
        raise VendorError(f"{path}: no sources")
    return entries
