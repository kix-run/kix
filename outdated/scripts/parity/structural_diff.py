"""
Structural diff engine for comparing Kubernetes resources as data structures.

Instead of serializing to JSON and doing string diffs, this walks both data
trees in parallel and reports differences by JSON path. This means:
- Dict key ordering doesn't matter (dicts are inherently unordered)
- Differences are reported as semantic operations (missing, extra, changed)
- Output shows exact JSON paths to each difference

The structural approach lets kix produce semantically equivalent output without
needing to match Helm's exact formatting, field ordering, or whitespace.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class DiffKind(Enum):
    """Type of structural difference between two values."""
    MISSING_IN_KIX = "missing_in_kix"   # Key exists in Helm but not kix
    EXTRA_IN_KIX = "extra_in_kix"       # Key exists in kix but not Helm
    VALUE_MISMATCH = "value_mismatch"   # Both have the key but values differ
    TYPE_MISMATCH = "type_mismatch"     # Same key, different types (e.g. str vs int)


@dataclass
class Difference:
    """A single structural difference at a specific JSON path."""
    path: str
    kind: DiffKind
    helm_value: Any = None
    kix_value: Any = None

    def __str__(self) -> str:
        match self.kind:
            case DiffKind.MISSING_IN_KIX:
                return f"  - {self.path}: {_compact(self.helm_value)}"
            case DiffKind.EXTRA_IN_KIX:
                return f"  + {self.path}: {_compact(self.kix_value)}"
            case DiffKind.VALUE_MISMATCH:
                return (
                    f"  ~ {self.path}:\n"
                    f"      helm: {_compact(self.helm_value)}\n"
                    f"      kix:  {_compact(self.kix_value)}"
                )
            case DiffKind.TYPE_MISMATCH:
                return (
                    f"  ! {self.path}: type mismatch\n"
                    f"      helm: {type(self.helm_value).__name__} = {_compact(self.helm_value)}\n"
                    f"      kix:  {type(self.kix_value).__name__} = {_compact(self.kix_value)}"
                )


def _compact(value: Any, max_len: int = 120) -> str:
    """Compact representation of a value for diff output.

    For simple scalars, show the value directly. For complex structures,
    show a truncated repr to keep output readable.
    """
    if value is None:
        return "null"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        # Show short strings directly, quote longer ones
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
    helm: Any,
    kix: Any,
    path: str = "$",
    ignore_paths: set[str] | None = None,
) -> list[Difference]:
    """Compare two values structurally, returning all differences.

    Args:
        helm: The Helm-side value (expected).
        kix: The kix-side value (actual).
        path: Current JSON path (for recursion). Root is "$".
        ignore_paths: Set of JSON path patterns to skip. Supports:
            - Exact paths: "$.spec.template.metadata.annotations"
            - Suffix wildcards: "*.annotations" matches any path ending in .annotations
            - Array wildcards: "$..containers[*].image" is NOT supported (keep it simple)

    Returns:
        List of Difference objects describing all structural differences.
    """
    if ignore_paths and _path_ignored(path, ignore_paths):
        return []

    diffs: list[Difference] = []

    # Both None/missing — equal
    if helm is None and kix is None:
        return []

    # Type mismatch — report and don't recurse
    if type(helm) is not type(kix):
        # Special case: treat int/float as compatible numeric types
        if isinstance(helm, (int, float)) and isinstance(kix, (int, float)):
            if helm != kix:
                diffs.append(Difference(path, DiffKind.VALUE_MISMATCH, helm, kix))
            return diffs
        diffs.append(Difference(path, DiffKind.TYPE_MISMATCH, helm, kix))
        return diffs

    # Dicts — compare keys
    if isinstance(helm, dict):
        all_keys = set(helm.keys()) | set(kix.keys())
        for key in sorted(all_keys):
            child_path = f"{path}.{key}"
            if ignore_paths and _path_ignored(child_path, ignore_paths):
                continue
            if key not in kix:
                diffs.append(Difference(child_path, DiffKind.MISSING_IN_KIX, helm[key]))
            elif key not in helm:
                diffs.append(Difference(child_path, DiffKind.EXTRA_IN_KIX, kix_value=kix[key]))
            else:
                diffs.extend(structural_diff(helm[key], kix[key], child_path, ignore_paths))
        return diffs

    # Lists — compare element-by-element (order-sensitive; normalization
    # already sorted order-insensitive arrays in the normalize step)
    if isinstance(helm, list):
        for i in range(max(len(helm), len(kix))):
            child_path = f"{path}[{i}]"
            if i >= len(kix):
                diffs.append(Difference(child_path, DiffKind.MISSING_IN_KIX, helm[i]))
            elif i >= len(helm):
                diffs.append(Difference(child_path, DiffKind.EXTRA_IN_KIX, kix_value=kix[i]))
            else:
                diffs.extend(structural_diff(helm[i], kix[i], child_path, ignore_paths))
        return diffs

    # Scalars — direct comparison
    if helm != kix:
        diffs.append(Difference(path, DiffKind.VALUE_MISMATCH, helm, kix))

    return diffs


def _path_ignored(path: str, ignore_paths: set[str]) -> bool:
    """Check if a path matches any ignore pattern.

    Supports:
    - Exact match: "$.metadata.annotations"
    - Suffix match: "*.annotations" — matches any path ending with ".annotations"
    """
    if path in ignore_paths:
        return True
    for pattern in ignore_paths:
        if pattern.startswith("*") and path.endswith(pattern[1:]):
            return True
    return False


def format_diffs(diffs: list[Difference]) -> str:
    """Format a list of differences for terminal output."""
    if not diffs:
        return ""
    return "\n".join(str(d) for d in diffs)
