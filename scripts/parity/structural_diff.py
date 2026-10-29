"""
Structural diff engine for comparing Kubernetes resources as data structures.

Instead of serializing to JSON and doing string diffs, this walks both data
trees in parallel and reports differences by JSON path. This means:
- Dict key ordering doesn't matter (dicts are inherently unordered)
- Differences are reported as semantic operations (missing, extra, and changed)
- Output shows exact JSON paths to each difference

The structural approach lets Kix produce semantically equivalent output without
needing to match the cluster's exact formatting, field ordering, or whitespace.
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable


class DiffKind(Enum):
    """Type of structural difference between two values."""

    MISSING_IN_B = "missing_in_b"  # Key exists in A but not B
    EXTRA_IN_B = "extra_in_b"  # Key exists in B but not A
    VALUE_MISMATCH = "value_mismatch"  # Both have the key but values differ
    TYPE_MISMATCH = "type_mismatch"  # Same key, different types (e.g. str vs int)


@dataclass
class Difference:
    """A single structural difference at a specific JSON path."""

    path: str
    kind: DiffKind
    a_value: Any = None
    b_value: Any = None
    a_label: str = "a"
    b_label: str = "b"

    def __str__(self) -> str:
        match self.kind:
            case DiffKind.MISSING_IN_B:
                return f"  - {self.path}: {_compact(self.a_value)}"
            case DiffKind.EXTRA_IN_B:
                return f"  + {self.path}: {_compact(self.b_value)}"
            case DiffKind.VALUE_MISMATCH:
                return (
                    f"  ~ {self.path}:\n"
                    f"      {self.a_label}: {_compact(self.a_value)}\n"
                    f"      {self.b_label}: {_compact(self.b_value)}"
                )
            case DiffKind.TYPE_MISMATCH:
                return (
                    f"  ! {self.path}: type mismatch\n"
                    f"      {self.a_label}: {type(self.a_value).__name__} = {_compact(self.a_value)}\n"
                    f"      {self.b_label}: {type(self.b_value).__name__} = {_compact(self.b_value)}"
                )


def _compact(value: Any, max_len: int = 120, full: bool = False) -> str:
    """Format a compact representation of a value for diff output.

    If *full* is True, strings and collections are never truncated.
    """
    if value is None:
        return "null"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        if full:
            return repr(value)
        if len(value) <= max_len and "\n" not in value:
            return repr(value)
        lines = value.splitlines()
        return repr(lines[0][:80] + f"... ({len(lines)} lines)")
    if isinstance(value, (dict, list)):
        r = repr(value)
        if full or len(r) <= max_len:
            return r
        return r[: max_len - 3] + "..."
    return repr(value)


# Natural key extractors for common Kubernetes array fields.
# Used to match list items by identity rather than position.
_LIST_KEY_EXTRACTORS: dict[str, Callable[[dict], str]] = {
    "containers": lambda item: item.get("name", ""),
    "initContainers": lambda item: item.get("name", ""),
    "ports": lambda item: (
        item.get("name", "")
        or f"{item.get('containerPort', item.get('port', ''))}:{item.get('protocol', 'TCP')}"
    ),
    "volumes": lambda item: item.get("name", ""),
    "volumeMounts": lambda item: item.get("mountPath", ""),
    "env": lambda item: item.get("name", ""),
    "hostAliases": lambda item: item.get("ip", ""),
    "subjects": lambda item: f"{item.get('kind', '')}:{item.get('name', '')}",
    "groups": lambda item: item.get("name", ""),
    "volumeClaimTemplates": lambda item: item.get("metadata", {}).get("name", ""),
    "webhooks": lambda item: item.get("name", ""),
    "topologySpreadConstraints": lambda item: item.get("topologyKey", ""),
    "tolerations": lambda item: (
        f"{item.get('key', '')}:{item.get('operator', '')}:{item.get('effect', '')}"
    ),
    "imagePullSecrets": lambda item: item.get("name", ""),
    "ownerReferences": lambda item: f"{item.get('kind', '')}:{item.get('name', '')}",
    "endpoints": lambda item: (
        item.get("port", "") or item.get("targetPort", "") or item.get("path", "")
    ),
}


def _normalize(value: Any) -> Any:
    """Deep-sort all lists within a value so order doesn't affect comparison."""
    if isinstance(value, dict):
        return {k: _normalize(v) for k, v in value.items()}
    if isinstance(value, list):
        return sorted((_normalize(v) for v in value), key=_sort_key)
    return value


def _sort_key(value: Any) -> tuple:
    """Return a canonical sort key for any value, so lists can be sorted regardless of element type."""
    if value is None:
        return (0,)
    if isinstance(value, bool):
        return (1, value)
    if isinstance(value, (int, float)):
        return (2, value)
    if isinstance(value, str):
        return (3, value)
    if isinstance(value, list):
        return (4, tuple(_sort_key(v) for v in value))
    if isinstance(value, dict):
        return (5, tuple(sorted((k, _sort_key(v)) for k, v in value.items())))
    return (6, str(value))


def _path_leaf(path: str) -> str:
    """Extract the last field name from a JSON path, stripping array indices."""
    part = path.rsplit(".", 1)[-1]
    idx = part.find("[")
    return part[:idx] if idx >= 0 else part


def _get_list_key_fn(parent_key: str, a: list, b: list) -> Callable[[dict], str] | None:
    """Get a key function for matching list items, or None to fall back to index-based."""
    if parent_key not in _LIST_KEY_EXTRACTORS:
        return None
    if not all(isinstance(item, dict) for item in a + b):
        return None
    key_fn = _LIST_KEY_EXTRACTORS[parent_key]
    # Fall back to index-based if keys aren't unique within either list
    a_keys = [key_fn(item) for item in a]
    b_keys = [key_fn(item) for item in b]
    if len(a_keys) != len(set(a_keys)) or len(b_keys) != len(set(b_keys)):
        return None
    return key_fn


def _diff_keyed_list(
    a: list,
    b: list,
    path: str,
    key_fn: Callable[[dict], str],
    ignore_paths: set[str] | None,
    a_label: str,
    b_label: str,
) -> list[Difference]:
    """Diff two lists of dicts by matching items on a natural key."""
    diffs: list[Difference] = []

    a_by_key = {key_fn(item): item for item in a}
    b_by_key = {key_fn(item): item for item in b}

    # Preserve insertion order: a's keys first, then b-only keys
    all_keys = list(dict.fromkeys(list(a_by_key.keys()) + list(b_by_key.keys())))

    for key in all_keys:
        child_path = f"{path}[{key}]"
        if ignore_paths and _path_ignored(child_path, ignore_paths):
            continue
        if key in a_by_key and key in b_by_key:
            diffs.extend(
                structural_diff(
                    a_by_key[key],
                    b_by_key[key],
                    child_path,
                    ignore_paths,
                    a_label,
                    b_label,
                )
            )
        elif key in a_by_key:
            diffs.append(
                Difference(
                    child_path,
                    DiffKind.MISSING_IN_B,
                    a_by_key[key],
                    a_label=a_label,
                    b_label=b_label,
                )
            )
        else:
            diffs.append(
                Difference(
                    child_path,
                    DiffKind.EXTRA_IN_B,
                    b_value=b_by_key[key],
                    a_label=a_label,
                    b_label=b_label,
                )
            )

    return diffs


def structural_diff(
    a: Any,
    b: Any,
    path: str = "$",
    ignore_paths: set[str] | None = None,
    a_label: str = "a",
    b_label: str = "b",
) -> list[Difference]:
    """Compare two values structurally, returning all differences.

    Args:
        a: The first value (e.g. Kix side).
        b: The second value (e.g. cluster side).
        path: Current JSON path (for recursion). Root is "$".
        ignore_paths: Set of JSON path patterns to skip. Supports:
            - Exact paths: "$.spec.template.metadata.annotations"
            - Suffix wildcards: "*.annotations" matches any path ending in .annotations
        a_label: Label for side A in output (e.g. "kix").
        b_label: Label for side B in output (e.g. "cluster").

    Returns:
        List of Difference objects describing all structural differences.
    """
    if ignore_paths and _path_ignored(path, ignore_paths):
        return []

    diffs: list[Difference] = []

    if a is None and b is None:
        return []

    # Type mismatch
    if type(a) is not type(b):
        if isinstance(a, (int, float)) and isinstance(b, (int, float)):
            if a != b:
                diffs.append(
                    Difference(path, DiffKind.VALUE_MISMATCH, a, b, a_label, b_label)
                )
            return diffs
        # K8s IntOrString: a numeric string and an int/float that parse to the
        # same number are semantically equal (e.g. resources.limits.cpu: '1' vs 1,
        # targetPort: '8443' vs 8443). Named ports like 'https' still diff.
        if _intorstring_equal(a, b):
            return diffs
        diffs.append(Difference(path, DiffKind.TYPE_MISMATCH, a, b, a_label, b_label))
        return diffs

    # Dicts
    if isinstance(a, dict):
        all_keys = set(a.keys()) | set(b.keys())
        for key in sorted(all_keys):
            child_path = f"{path}.{key}"
            if ignore_paths and _path_ignored(child_path, ignore_paths):
                continue
            if key not in b:
                diffs.append(
                    Difference(
                        child_path,
                        DiffKind.MISSING_IN_B,
                        a[key],
                        a_label=a_label,
                        b_label=b_label,
                    )
                )
            elif key not in a:
                diffs.append(
                    Difference(
                        child_path,
                        DiffKind.EXTRA_IN_B,
                        b_value=b[key],
                        a_label=a_label,
                        b_label=b_label,
                    )
                )
            else:
                diffs.extend(
                    structural_diff(
                        a[key], b[key], child_path, ignore_paths, a_label, b_label
                    )
                )
        return diffs

    # Lists: try key-based matching first, then fall back to content-based matching
    if isinstance(a, list):
        parent_key = _path_leaf(path)
        key_fn = _get_list_key_fn(parent_key, a, b)
        if key_fn is not None:
            return diffs + _diff_keyed_list(
                a, b, path, key_fn, ignore_paths, a_label, b_label
            )
        # Normalize both lists (deep-sort inner lists) and match by content
        a_normed = [_normalize(v) for v in a]
        b_normed = [_normalize(v) for v in b]
        # Build a canonical string key for each item to enable set-like matching
        a_keyed = [(repr(_sort_key(v)), v) for v in a_normed]
        b_keyed = [(repr(_sort_key(v)), v) for v in b_normed]
        a_by_key: dict[str, list] = {}
        for k, v in a_keyed:
            a_by_key.setdefault(k, []).append(v)
        b_by_key: dict[str, list] = {}
        for k, v in b_keyed:
            b_by_key.setdefault(k, []).append(v)
        all_keys = list(
            dict.fromkeys(
                [k for k, _ in sorted(a_keyed, key=lambda x: x[0])]
                + [k for k, _ in sorted(b_keyed, key=lambda x: x[0])]
            )
        )
        idx = 0
        for key in all_keys:
            a_items = a_by_key.get(key, [])
            b_items = b_by_key.get(key, [])
            # Match items pairwise (handles duplicates)
            paired = min(len(a_items), len(b_items))
            for j in range(paired):
                child_path = f"{path}[{idx}]"
                if ignore_paths and _path_ignored(child_path, ignore_paths):
                    idx += 1
                    continue
                diffs.extend(
                    structural_diff(
                        a_items[j],
                        b_items[j],
                        child_path,
                        ignore_paths,
                        a_label,
                        b_label,
                    )
                )
                idx += 1
            for j in range(paired, len(a_items)):
                child_path = f"{path}[{idx}]"
                diffs.append(
                    Difference(
                        child_path,
                        DiffKind.MISSING_IN_B,
                        a_items[j],
                        a_label=a_label,
                        b_label=b_label,
                    )
                )
                idx += 1
            for j in range(paired, len(b_items)):
                child_path = f"{path}[{idx}]"
                diffs.append(
                    Difference(
                        child_path,
                        DiffKind.EXTRA_IN_B,
                        b_value=b_items[j],
                        a_label=a_label,
                        b_label=b_label,
                    )
                )
                idx += 1
        return diffs

    # Scalars
    if a != b:
        # Check if both are equivalent K8s quantities (e.g. "1" vs "1000m", "2Gi" vs "2048Mi")
        if isinstance(a, str) and isinstance(b, str) and _quantities_equal(a, b):
            pass  # semantically equal quantities
        elif (
            isinstance(a, str)
            and isinstance(b, str)
            and "\n" in a
            and "\n" in b
            and _strip_comments(a) == _strip_comments(b)
        ):
            pass  # multi-line strings differ only in comment lines / blank lines
        else:
            diffs.append(
                Difference(path, DiffKind.VALUE_MISMATCH, a, b, a_label, b_label)
            )

    return diffs


# Matches K8s resource quantities like "500m", "1.5Gi", "100", and "2e3"
_QUANTITY_RE = re.compile(
    r"^([+-]?(?:\d+\.?\d*|\d*\.?\d+)(?:e[+-]?\d+)?)\s*"
    r"(n|u|m|k|Ki|Mi|Gi|Ti|Pi|Ei|M|G|T|P|E)?$"
)

_QUANTITY_MULTIPLIERS = {
    "n": 1e-9,
    "u": 1e-6,
    "m": 1e-3,
    "k": 1e3,
    "M": 1e6,
    "G": 1e9,
    "T": 1e12,
    "P": 1e15,
    "E": 1e18,
    "Ki": 2**10,
    "Mi": 2**20,
    "Gi": 2**30,
    "Ti": 2**40,
    "Pi": 2**50,
    "Ei": 2**60,
}


def _parse_quantity(s: str) -> float | None:
    """Parse a K8s resource quantity string to its base numeric value, or None if not a quantity."""
    m = _QUANTITY_RE.match(s)
    if not m:
        return None
    value = float(m.group(1))
    suffix = m.group(2)
    if suffix:
        value *= _QUANTITY_MULTIPLIERS[suffix]
    return value


def _intorstring_equal(a, b) -> bool:
    """Return whether two values are equal under K8s IntOrString semantics.

    K8s IntOrString fields tolerate '8443' == 8443. Named ports stay distinct.
    """
    if isinstance(a, bool) or isinstance(b, bool):
        return False
    if isinstance(a, str) and isinstance(b, (int, float)):
        s, n = a, b
    elif isinstance(b, str) and isinstance(a, (int, float)):
        s, n = b, a
    else:
        return False
    try:
        return float(s) == float(n)
    except ValueError:
        return False


_COMMENT_LINE_RE = re.compile(r"^\s*#.*$", re.MULTILINE)


def _strip_comments(s: str) -> str:
    """Strip whole-line comments and collapse blank lines for comparison."""
    no_comments = _COMMENT_LINE_RE.sub("", s)
    return "\n".join(line for line in no_comments.splitlines() if line.strip())


def _quantities_equal(a: str, b: str) -> bool:
    """Check if two strings represent the same K8s resource quantity."""
    qa = _parse_quantity(a)
    qb = _parse_quantity(b)
    if qa is None or qb is None:
        return False
    # Use relative tolerance for floating point
    if qa == qb == 0:
        return True
    return abs(qa - qb) / max(abs(qa), abs(qb)) < 1e-9


def _path_ignored(path: str, ignore_paths: set[str]) -> bool:
    """Check if a path matches any ignore pattern."""
    if path in ignore_paths:
        return True
    for pattern in ignore_paths:
        if pattern.startswith("*") and path.endswith(pattern[1:]):
            return True
    return False


def _multiline_diff(
    a: str,
    b: str,
    a_label: str,
    b_label: str,
    indent: str = "      ",
    color: bool = False,
) -> str:
    """Generate a unified diff for multi-line string values."""
    a_lines = a.splitlines(keepends=True)
    b_lines = b.splitlines(keepends=True)
    diff_lines = list(
        difflib.unified_diff(a_lines, b_lines, fromfile=a_label, tofile=b_label)
    )
    if not diff_lines:
        return f"{indent}(no differences)"
    result = []
    for line in diff_lines:
        line = line.rstrip("\n")
        if color:
            if line.startswith("---") or line.startswith("+++"):
                result.append(f"{indent}{_BOLD}{line}{_RESET}")
            elif line.startswith("-"):
                result.append(f"{indent}{_RED}{line}{_RESET}")
            elif line.startswith("+"):
                result.append(f"{indent}{_GREEN}{line}{_RESET}")
            elif line.startswith("@@"):
                result.append(f"{indent}{_CYAN}{line}{_RESET}")
            else:
                result.append(f"{indent}{line}")
        else:
            result.append(f"{indent}{line}")
    return "\n".join(result)


def _format_diff_plain(d: Difference, full_diff: bool = False) -> str:
    """Render a single Difference as plain text."""

    def _c(v):
        return _compact(v, full=full_diff)

    match d.kind:
        case DiffKind.MISSING_IN_B:
            return f"  - {d.path}: {_c(d.a_value)}"
        case DiffKind.EXTRA_IN_B:
            return f"  + {d.path}: {_c(d.b_value)}"
        case DiffKind.VALUE_MISMATCH:
            if (
                full_diff
                and isinstance(d.a_value, str)
                and isinstance(d.b_value, str)
                and ("\n" in d.a_value or "\n" in d.b_value)
            ):
                return f"  ~ {d.path}:\n" + _multiline_diff(
                    d.a_value, d.b_value, d.a_label, d.b_label
                )
            return f"  ~ {d.path}:\n      {d.a_label}: {_c(d.a_value)}\n      {d.b_label}: {_c(d.b_value)}"
        case DiffKind.TYPE_MISMATCH:
            return (
                f"  ! {d.path}: type mismatch\n"
                f"      {d.a_label}: {type(d.a_value).__name__} = {_c(d.a_value)}\n"
                f"      {d.b_label}: {type(d.b_value).__name__} = {_c(d.b_value)}"
            )
    return str(d)


def format_diffs(
    diffs: list[Difference], color: bool = False, full_diff: bool = False
) -> str:
    """Format a list of differences for terminal output.

    If *color* is True, ANSI escape codes are used to highlight lines:
    - Red for missing-in-B (only in Kix)
    - Green for extra-in-B (only in cluster)
    - Yellow for value/type mismatches

    If *full_diff* is True, multi-line string values are shown as unified diffs.
    """
    if not diffs:
        return ""
    if not color:
        return "\n".join(_format_diff_plain(d, full_diff=full_diff) for d in diffs)
    return "\n".join(_colorize_diff(d, full_diff=full_diff) for d in diffs)


# ANSI helpers
_RED = "\033[31m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"
_DIM = "\033[2m"
_BOLD = "\033[1m"
_RESET = "\033[0m"


def _colorize_diff(d: Difference, full_diff: bool = False) -> str:
    """Render a single Difference with ANSI colour codes."""

    def _c(v):
        return _compact(v, full=full_diff)

    match d.kind:
        case DiffKind.MISSING_IN_B:
            return f"  {_RED}{_BOLD}-{_RESET} {_DIM}{d.path}:{_RESET} {_RED}{_c(d.a_value)}{_RESET}"
        case DiffKind.EXTRA_IN_B:
            return f"  {_GREEN}{_BOLD}+{_RESET} {_DIM}{d.path}:{_RESET} {_GREEN}{_c(d.b_value)}{_RESET}"
        case DiffKind.VALUE_MISMATCH:
            if (
                full_diff
                and isinstance(d.a_value, str)
                and isinstance(d.b_value, str)
                and ("\n" in d.a_value or "\n" in d.b_value)
            ):
                diff_text = _multiline_diff(
                    d.a_value, d.b_value, d.a_label, d.b_label, color=True
                )
                return (
                    f"  {_YELLOW}{_BOLD}~{_RESET} {_DIM}{d.path}:{_RESET}\n{diff_text}"
                )
            return (
                f"  {_YELLOW}{_BOLD}~{_RESET} {_DIM}{d.path}:{_RESET}\n"
                f"      {_RED}{d.a_label}: {_c(d.a_value)}{_RESET}\n"
                f"      {_GREEN}{d.b_label}: {_c(d.b_value)}{_RESET}"
            )
        case DiffKind.TYPE_MISMATCH:
            return (
                f"  {_CYAN}{_BOLD}!{_RESET} {_DIM}{d.path}:{_RESET} type mismatch\n"
                f"      {_RED}{d.a_label}: {type(d.a_value).__name__} = {_c(d.a_value)}{_RESET}\n"
                f"      {_GREEN}{d.b_label}: {type(d.b_value).__name__} = {_c(d.b_value)}{_RESET}"
            )
