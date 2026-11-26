"""Shared routines for vendoring upstream CRDs and operator RBAC into kix
packages.

`scripts/vendor-crds.py` is the driver. A package's `crds/update.py` (the
escape hatch for an upstream that is not a public URL) imports from here so
there is one copy of fetch, parse and render. See
discussions/146_crd_vendoring_and_upgrades.md.
"""

from __future__ import annotations

import json
import pathlib
import re
import time
import urllib.error
import urllib.request

import yaml

USER_AGENT = "kix-vendor-crds (+https://github.com/kix-run/kix)"
CRD_KIND = "CustomResourceDefinition"
RBAC_KINDS = ("ClusterRole", "Role")


class VendorError(Exception):
    """A problem with one package's sources; reported, never a traceback."""


class _Loader(yaml.SafeLoader):
    """SafeLoader that reads a plain `=` as the string "=", as Kubernetes
    does. PyYAML resolves it to the YAML 1.1 `value` tag, which SafeLoader
    cannot construct, so an enum listing `- =` would fail to parse."""


_Loader.yaml_implicit_resolvers = {
    first: [
        (tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:value"
    ]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


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
        documents = list(yaml.load_all(text, Loader=_Loader))
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
                "vendor yet (discussions/146 §8)"
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
    """The ClusterRoles and Roles that `selectors` name as `Kind/name`,
    sorted by selector. Every selector must match a document. Other kinds
    are refused, because a package builds its own bindings and service
    accounts, and a URL without selectors is refused, because an operator
    bundle holds roles for several service accounts."""
    if not selectors:
        raise VendorError(f"{source}: name the roles to take from it, as Kind/name")
    for kind, _, name in sorted(s.partition("/") for s in selectors):
        if kind not in RBAC_KINDS or not name:
            raise VendorError(
                f"{source}: {kind}/{name}: not ClusterRole/name or Role/name"
            )
    by_selector = {
        f"{d.get('kind')}/{d.get('metadata', {}).get('name')}": d
        for d in documents_in(text, source)
    }
    missing = sorted(selectors - by_selector.keys())
    if missing:
        raise VendorError(f"{source}: does not contain {', '.join(missing)}")
    return [by_selector[s] for s in sorted(selectors)]


def render(crd: dict) -> str:
    """What gets committed: the whole upstream object, sorted, so a refresh
    diff reads as what moved upstream."""
    return json.dumps(crd, indent=2, sort_keys=True) + "\n"


def file_name(obj: dict) -> str:
    """`<metadata.name>.json` for a CRD. `<kind>-<name>.json` for a role,
    with `:` written as `_` (`clusterrole-kubevirt.io_operator.json`)."""
    name = obj["metadata"]["name"]
    if obj["kind"] == CRD_KIND:
        return f"{name}.json"
    if not re.fullmatch(r"[a-z0-9.:-]+", name):
        raise VendorError(f"{obj['kind']}/{name}: no file name mapping for this name")
    return f"{obj['kind'].lower()}-{name.replace(':', '_')}.json"


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
