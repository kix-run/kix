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

from dataclasses import dataclass
from enum import Enum
from typing import Any


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

    # Lists
    if isinstance(a, list):
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


def format_diffs(diffs: list[Difference], color: bool = False) -> str:
    """Format a list of differences for terminal output.

    If *color* is True, ANSI escape codes are used to highlight lines:
    - Red for missing-in-B (only in kix)
    - Green for extra-in-B (only in cluster)
    - Yellow for value/type mismatches
    """
    if not diffs:
        return ""
    if not color:
        return "\n".join(str(d) for d in diffs)
    return "\n".join(_colorize_diff(d) for d in diffs)


# ANSI helpers
_RED = "\033[31m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"
_DIM = "\033[2m"
_BOLD = "\033[1m"
_RESET = "\033[0m"


def _colorize_diff(d: Difference) -> str:
    """Render a single Difference with ANSI colour codes."""
    match d.kind:
        case DiffKind.MISSING_IN_B:
            return f"  {_RED}{_BOLD}-{_RESET} {_DIM}{d.path}:{_RESET} {_RED}{_compact(d.a_value)}{_RESET}"
        case DiffKind.EXTRA_IN_B:
            return f"  {_GREEN}{_BOLD}+{_RESET} {_DIM}{d.path}:{_RESET} {_GREEN}{_compact(d.b_value)}{_RESET}"
        case DiffKind.VALUE_MISMATCH:
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
