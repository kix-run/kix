"""
Structural diff engine for comparing Kubernetes resources as data structures.

Instead of serializing to JSON and doing string diffs, this walks both data
trees in parallel and reports differences by JSON path. This means:
- Dict key ordering doesn't matter (dicts are inherently unordered)
- Differences are reported as semantic operations (missing, extra, changed)
- Output shows exact JSON paths to each difference

The structural approach lets kix produce semantically equivalent output without
needing to match the cluster's exact formatting, field ordering, or whitespace.
"""

from __future__ import annotations

import difflib
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable


class DiffKind(Enum):
    """Type of structural difference between two values."""
    MISSING_IN_B = "missing_in_b"   # Key exists in A but not B
    EXTRA_IN_B = "extra_in_b"       # Key exists in B but not A
    VALUE_MISMATCH = "value_mismatch"   # Both have the key but values differ
    TYPE_MISMATCH = "type_mismatch"     # Same key, different types (e.g. str vs int)


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


def _compact(value: Any, max_len: int = 120) -> str:
    """Compact representation of a value for diff output."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        if len(value) <= max_len and "\n" not in value:
            return repr(value)
        lines = value.splitlines()
        return repr(lines[0][:80] + f"... ({len(lines)} lines)")
    if isinstance(value, (dict, list)):
        r = repr(value)
        if len(r) <= max_len:
            return r
        return r[:max_len - 3] + "..."
    return repr(value)


# Natural key extractors for common Kubernetes array fields.
# Used to match list items by identity rather than position.
_LIST_KEY_EXTRACTORS: dict[str, Callable[[dict], str]] = {
    "containers": lambda item: item.get("name", ""),
    "initContainers": lambda item: item.get("name", ""),
    "ports": lambda item: item.get("name", "") or f"{item.get('containerPort', item.get('port', ''))}:{item.get('protocol', 'TCP')}",
    "volumes": lambda item: item.get("name", ""),
    "volumeMounts": lambda item: item.get("mountPath", ""),
    "env": lambda item: item.get("name", ""),
    "hostAliases": lambda item: item.get("ip", ""),
    "subjects": lambda item: f"{item.get('kind', '')}:{item.get('name', '')}",
}


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
            diffs.extend(structural_diff(
                a_by_key[key], b_by_key[key], child_path,
                ignore_paths, a_label, b_label,
            ))
        elif key in a_by_key:
            diffs.append(Difference(child_path, DiffKind.MISSING_IN_B, a_by_key[key], a_label=a_label, b_label=b_label))
        else:
            diffs.append(Difference(child_path, DiffKind.EXTRA_IN_B, b_value=b_by_key[key], a_label=a_label, b_label=b_label))

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
        a: The first value (e.g. kix side).
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
                diffs.append(Difference(path, DiffKind.VALUE_MISMATCH, a, b, a_label, b_label))
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
                diffs.append(Difference(child_path, DiffKind.MISSING_IN_B, a[key], a_label=a_label, b_label=b_label))
            elif key not in a:
                diffs.append(Difference(child_path, DiffKind.EXTRA_IN_B, b_value=b[key], a_label=a_label, b_label=b_label))
            else:
                diffs.extend(structural_diff(a[key], b[key], child_path, ignore_paths, a_label, b_label))
        return diffs

    # Lists — try key-based matching first, fall back to index-based
    if isinstance(a, list):
        parent_key = _path_leaf(path)
        key_fn = _get_list_key_fn(parent_key, a, b)
        if key_fn is not None:
            return diffs + _diff_keyed_list(a, b, path, key_fn, ignore_paths, a_label, b_label)
        for i in range(max(len(a), len(b))):
            child_path = f"{path}[{i}]"
            if i >= len(b):
                diffs.append(Difference(child_path, DiffKind.MISSING_IN_B, a[i], a_label=a_label, b_label=b_label))
            elif i >= len(a):
                diffs.append(Difference(child_path, DiffKind.EXTRA_IN_B, b_value=b[i], a_label=a_label, b_label=b_label))
            else:
                diffs.extend(structural_diff(a[i], b[i], child_path, ignore_paths, a_label, b_label))
        return diffs

    # Scalars
    if a != b:
        diffs.append(Difference(path, DiffKind.VALUE_MISMATCH, a, b, a_label, b_label))

    return diffs


def _path_ignored(path: str, ignore_paths: set[str]) -> bool:
    """Check if a path matches any ignore pattern."""
    if path in ignore_paths:
        return True
    for pattern in ignore_paths:
        if pattern.startswith("*") and path.endswith(pattern[1:]):
            return True
    return False


def _multiline_diff(a: str, b: str, a_label: str, b_label: str, indent: str = "      ", color: bool = False) -> str:
    """Generate a unified diff for multi-line string values."""
    a_lines = a.splitlines(keepends=True)
    b_lines = b.splitlines(keepends=True)
    diff_lines = list(difflib.unified_diff(a_lines, b_lines, fromfile=a_label, tofile=b_label))
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
    match d.kind:
        case DiffKind.MISSING_IN_B:
            return f"  - {d.path}: {_compact(d.a_value)}"
        case DiffKind.EXTRA_IN_B:
            return f"  + {d.path}: {_compact(d.b_value)}"
        case DiffKind.VALUE_MISMATCH:
            if (full_diff and isinstance(d.a_value, str) and isinstance(d.b_value, str)
                    and ("\n" in d.a_value or "\n" in d.b_value)):
                return (
                    f"  ~ {d.path}:\n"
                    + _multiline_diff(d.a_value, d.b_value, d.a_label, d.b_label)
                )
            return (
                f"  ~ {d.path}:\n"
                f"      {d.a_label}: {_compact(d.a_value)}\n"
                f"      {d.b_label}: {_compact(d.b_value)}"
            )
        case DiffKind.TYPE_MISMATCH:
            return (
                f"  ! {d.path}: type mismatch\n"
                f"      {d.a_label}: {type(d.a_value).__name__} = {_compact(d.a_value)}\n"
                f"      {d.b_label}: {type(d.b_value).__name__} = {_compact(d.b_value)}"
            )
    return str(d)


def format_diffs(diffs: list[Difference], color: bool = False, full_diff: bool = False) -> str:
    """Format a list of differences for terminal output.

    If *color* is True, ANSI escape codes are used to highlight lines:
    - Red for missing-in-B (only in kix)
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
    match d.kind:
        case DiffKind.MISSING_IN_B:
            return f"  {_RED}{_BOLD}-{_RESET} {_DIM}{d.path}:{_RESET} {_RED}{_compact(d.a_value)}{_RESET}"
        case DiffKind.EXTRA_IN_B:
            return f"  {_GREEN}{_BOLD}+{_RESET} {_DIM}{d.path}:{_RESET} {_GREEN}{_compact(d.b_value)}{_RESET}"
        case DiffKind.VALUE_MISMATCH:
            if (full_diff and isinstance(d.a_value, str) and isinstance(d.b_value, str)
                    and ("\n" in d.a_value or "\n" in d.b_value)):
                diff_text = _multiline_diff(d.a_value, d.b_value, d.a_label, d.b_label, color=True)
                return f"  {_YELLOW}{_BOLD}~{_RESET} {_DIM}{d.path}:{_RESET}\n{diff_text}"
            return (
                f"  {_YELLOW}{_BOLD}~{_RESET} {_DIM}{d.path}:{_RESET}\n"
                f"      {_RED}{d.a_label}: {_compact(d.a_value)}{_RESET}\n"
                f"      {_GREEN}{d.b_label}: {_compact(d.b_value)}{_RESET}"
            )
        case DiffKind.TYPE_MISMATCH:
            return (
                f"  {_CYAN}{_BOLD}!{_RESET} {_DIM}{d.path}:{_RESET} type mismatch\n"
                f"      {_RED}{d.a_label}: {type(d.a_value).__name__} = {_compact(d.a_value)}{_RESET}\n"
                f"      {_GREEN}{d.b_label}: {type(d.b_value).__name__} = {_compact(d.b_value)}{_RESET}"
            )
