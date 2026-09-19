"""Shared routines for vendoring upstream CRDs into kix packages.

`scripts/vendor-crds.py` is the driver. A package's `crds/update.py` (the
escape hatch for an upstream that is not a public URL) imports from here so
there is one copy of fetch, parse and render. See
v2_discussions/146_crd_vendoring_and_upgrades.md.
"""

from __future__ import annotations

import json
import pathlib
import time
import urllib.error
import urllib.request

import yaml

USER_AGENT = "kixpkgs-vendor-crds (+https://github.com/kix-run/kixpkgs)"
CRD_KIND = "CustomResourceDefinition"


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


def crds_in(text: bytes | str, *, source: str = "<input>") -> list[dict]:
    """Every CustomResourceDefinition document in a YAML stream.

    Other kinds (an operator bundle carries Deployments and RBAC alongside
    its CRDs) are ignored, so a whole upstream manifest is a valid source.
    """
    if isinstance(text, bytes):
        text = text.decode("utf-8")
    try:
        documents = list(yaml.safe_load_all(text))
    except yaml.YAMLError as error:
        raise VendorError(f"{source}: not YAML: {error}") from error
    found = [d for d in documents if isinstance(d, dict) and d.get("kind") == CRD_KIND]
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


def render(crd: dict) -> str:
    """What gets committed: the whole upstream object, sorted, so a refresh
    diff reads as what moved upstream."""
    return json.dumps(crd, indent=2, sort_keys=True) + "\n"


def file_name(crd: dict) -> str:
    return f"{crd['metadata']['name']}.json"


def parse_sources(path: pathlib.Path) -> list[tuple[str, set[str]]]:
    """`sources.txt`: one public URL per line, optionally followed by the
    names of the CRDs to take from it. Blank lines and `#` comments are
    ignored. A URL with no names contributes every CRD it holds."""
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
