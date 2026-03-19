"""Parse Nix exportReferencesGraph text format.

The legacy (non-structuredAttrs) format is:

    <store-path>
    <deriver-or-empty>
    <num-references>
    <ref-1>
    <ref-2>
    ...
    <next-store-path>
    ...

Returns a list of { "path": str, "references": [str] } dicts.
"""


def parse_closure_file(path):
    """Parse a Nix exportReferencesGraph text file into a list of entries."""
    with open(path) as f:
        lines = f.read().strip().split("\n")

    entries = []
    i = 0
    while i < len(lines):
        store_path = lines[i]
        i += 1
        # deriver (or empty string)
        _deriver = lines[i] if i < len(lines) else ""
        i += 1
        # number of references
        num_refs = int(lines[i]) if i < len(lines) else 0
        i += 1
        refs = []
        for _ in range(num_refs):
            if i < len(lines):
                refs.append(lines[i])
                i += 1
        entries.append({
            "path": store_path,
            "references": refs,
        })

    return entries
