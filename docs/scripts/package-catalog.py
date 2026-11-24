#!/usr/bin/env python3
"""Write the package catalog pages from the data docs/nix/reference.nix reads.

Input:
    --data     JSON list, one object per package (see `packageData` in
               docs/nix/reference.nix).
    --ledger   docs/how-to-coverage.json. A page entry's `packages` lists the
               ids of the packages the guide is about.
    --guides   docs/src/content/docs/how-to, to read each guide's title.
    --out      Directory to write. It receives `index.mdx`, `<name>.mdx` for
               each stable package, and `experimental/<name>.mdx` for each
               experimental package, so a rework that shares a stable
               package's name gets its own page.

The pages are MDX, so text taken from packages has `{`, `}`, and `<` escaped
outside code.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# Text a reader sees that does not come from package data. Kept together so
# a copy edit touches one place.
TEXT = {
    "index_title": "Package catalog",
    "index_description": "Every ready-made package that Kix ships, with its stability level, how to name it in a cluster, dependencies, and options.",
    "index_intro": "This catalog lists every ready-made package that Kix ships, its stability level, and how to name it in a cluster definition. Each linked page documents the package's dependencies, its typed options, and any upstream version it declares. The docs build generates every page from the package source in the Kix repository, so the catalog matches the Kix version these docs describe. Reach for this catalog when checking whether Kix includes a package or looking up how to configure one.",
    "index_background": ":::note[Helpful background]\n- [Stable and experimental packages](/docs/reference/instances-and-composition/#stable-and-experimental-packages): see what each stability level guarantees and how to name stable and experimental packages in a cluster.\n- [Packages and clusters](/docs/explanation/packages-and-clusters/): understand how reusable packages relate to the package instances deployed in a cluster.\n- [Package anatomy](/docs/reference/package-anatomy/): learn what a package's `meta`, `options`, and `build` sections mean.\n- [List clusters and packages](/docs/how-to/start-and-inspect/list-clusters-and-packages/): run `kix list packages` to list available packages from the command line.\n:::",
    "col_package": "Package",
    "col_stability": "Stability",
    "col_spelling": "Name in a cluster",
    "col_description": "Description",
    "stable": "Stable",
    "experimental": "Experimental",
    "page_generated": "This page is generated from {source} on every docs build.",
    "field_stability": "Stability",
    "field_spelling": "Name in a cluster",
    "field_version": "Upstream version",
    "field_aliases": "Default aliases",
    "field_roles": "Roles",
    "field_availability": "Highest availability level",
    "deprecated_title": "Deprecated",
    "deprecated_replacement": "Replacement: {replacement}",
    "deps_heading": "Dependencies",
    "deps_intro": "Each entry below names another package instance that this package asks for, matched by instance name, alias, or role. See [Declaring dependencies](/docs/reference/package-anatomy/#declaring-dependencies) for how Kix resolves required and optional dependencies.",
    "col_dependency": "Dependency",
    "col_required": "Requirement",
    "required": "Required",
    "optional": "Optional",
    "guides_heading": "How-to guides",
    "options_heading": "Options",
    "options_none": "This package declares no options.",
    "option_type": "Type",
    "option_default": "Default",
    "option_example": "Example",
    "option_read_only": "Read-only",
    "error_no_description": "Package {id} in {source}/default.nix has a missing or empty meta.description. The docs build cannot generate its package catalog page without one. Add a one-line meta.description to {source}/default.nix.",
    "error_unknown_package": 'Entry "{page}" in docs/how-to-coverage.json lists unknown package id "{id}" under packages. The docs build cannot link that how-to guide into the package catalog. The package may have been renamed, removed, or moved from experimental to stable. Update or remove "{id}" in docs/how-to-coverage.json, using the folder name for a stable package or "experimental/<name>" for an experimental one.',
    "error_missing_guide": 'Entry "{page}" in docs/how-to-coverage.json points to missing how-to page file {path}. The docs build cannot link that guide from the package catalog. Create {path}, or update or remove "{page}" in docs/how-to-coverage.json.',
}

FENCE = re.compile(r"^(\s*)(```+|~~~+)")
CODE_SPAN = re.compile(r"(`+)(.+?)\1", re.S)


def escape_text(text: str) -> str:
    return re.sub(r"([{}<])", r"\\\1", text)


def escape_inline(text: str) -> str:
    """Escape MDX syntax in a line of Markdown, leaving code spans alone."""
    out, pos = [], 0
    for m in CODE_SPAN.finditer(text):
        out.append(escape_text(text[pos : m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(escape_text(text[pos:]))
    return "".join(out)


def escape_markdown(text: str) -> str:
    """Escape MDX syntax in Markdown, leaving fenced blocks and code spans alone."""
    lines, block, fence = [], [], None
    for line in text.splitlines():
        m = FENCE.match(line)
        if fence is None and m:
            if block:
                lines.append(escape_inline("\n".join(block)))
                block = []
            fence = m.group(2)
            lines.append(line)
        elif fence is not None:
            lines.append(line)
            if line.strip().startswith(fence):
                fence = None
        else:
            block.append(line)
    if block:
        lines.append(escape_inline("\n".join(block)))
    return "\n".join(lines).strip()


def code(text: str) -> str:
    ticks = "`"
    while ticks in text:
        ticks += "`"
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return f"{ticks}{pad}{text}{pad}{ticks}"


def table_cell(markdown: str) -> str:
    return markdown.replace("|", "\\|").replace("\n", " ")


def frontmatter(fields: dict) -> str:
    # A JSON string is a valid YAML double-quoted scalar.
    lines = ["---"]
    for key, value in fields.items():
        if isinstance(value, str):
            lines.append(f"{key}: {json.dumps(value)}")
        else:
            lines.append(f"{key}:")
            lines.extend("  " + line for line in value)
    lines.append("---")
    return "\n".join(lines)


def rendered_value(value: dict) -> str:
    """Render a default or example, which Nix gives as `{ _type; text; }`.

    The result follows a label on the same line, so it starts with a space,
    or with a blank line for a block.
    """
    text = value["text"].strip()
    if value.get("_type") == "literalMD":
        rendered = escape_markdown(text)
    elif "\n" in text:
        rendered = f"```nix\n{text}\n```"
    else:
        return " " + code(text)
    if "\n" not in rendered:
        return " " + rendered
    # Indent a block so that it stays inside its list item.
    return "\n\n" + "\n".join(
        "  " + line if line else "" for line in rendered.splitlines()
    )


def page_path(package: dict) -> str:
    return package["id"]


def page_url(package: dict) -> str:
    return f"/docs/reference/package-catalog/{page_path(package)}/"


def guide_title(guides_root: pathlib.Path, page: str) -> str:
    path = guides_root / f"{page}.mdx"
    if not path.is_file():
        sys.exit(TEXT["error_missing_guide"].format(page=page, path=path))
    header = path.read_text().split("---")[1]
    title = re.search(r"^title:\s*(.+)$", header, re.M).group(1).strip()
    return json.loads(title) if title.startswith('"') else title


def guides_by_package(ledger: dict, guides_root: pathlib.Path, ids: set[str]) -> dict:
    found: dict[str, list[tuple[str, str]]] = {}
    for entry in ledger.get("pages", []):
        for package_id in entry.get("packages", []):
            if package_id not in ids:
                sys.exit(
                    TEXT["error_unknown_package"].format(
                        page=entry["page"], id=package_id
                    )
                )
            title = guide_title(guides_root, entry["page"])
            found.setdefault(package_id, []).append(
                (title, f"/docs/how-to/{entry['page']}/")
            )
    return found


def option_section(option: dict) -> str:
    parts = [f"### {code(option['name'])}"]
    if option.get("description"):
        parts.append(escape_markdown(option["description"]))
    facts = [f"- **{TEXT['option_type']}:** {code(option['type'])}"]
    if "default" in option:
        facts.append(
            f"- **{TEXT['option_default']}:**{rendered_value(option['default'])}"
        )
    if "example" in option:
        facts.append(
            f"- **{TEXT['option_example']}:**{rendered_value(option['example'])}"
        )
    if option.get("readOnly"):
        facts.append(f"- **{TEXT['option_read_only']}**")
    parts.append("\n".join(facts))
    return "\n\n".join(parts)


def package_page(package: dict, guides: list[tuple[str, str]]) -> str:
    meta = package["meta"]
    level = package["level"]
    fields = {
        "title": package["name"],
        "description": meta["description"],
        "tableOfContents": ["maxHeadingLevel: 2"],
    }
    if level == "experimental":
        fields["sidebar"] = [
            "badge:",
            f"  text: {TEXT['experimental']}",
            "  variant: caution",
        ]

    facts = [
        (TEXT["field_stability"], TEXT[level]),
        (TEXT["field_spelling"], code(package["spelling"])),
    ]
    if meta["version"]:
        facts.append((TEXT["field_version"], code(meta["version"])))
    if meta["defaultAliases"]:
        facts.append(
            (TEXT["field_aliases"], ", ".join(code(a) for a in meta["defaultAliases"]))
        )
    if meta["roles"]:
        facts.append((TEXT["field_roles"], ", ".join(code(r) for r in meta["roles"])))
    if meta["availabilityMax"]:
        facts.append((TEXT["field_availability"], code(meta["availabilityMax"])))

    body = [
        frontmatter(fields),
        "",
        escape_markdown(meta["description"]),
        "",
        TEXT["page_generated"].format(
            source=f"[`kix/packages/{level}/{package['name']}`]({package['source']})"
        ),
        "",
        "| | |\n| --- | --- |",
    ]
    body[-1] += "".join(
        f"\n| {label} | {table_cell(value)} |" for label, value in facts
    )

    deprecated = meta["deprecated"]
    if deprecated:
        aside = [
            f":::caution[{TEXT['deprecated_title']}]",
            escape_markdown(deprecated["message"]),
        ]
        if deprecated.get("replacement"):
            aside += [
                "",
                TEXT["deprecated_replacement"].format(
                    replacement=code(deprecated["replacement"])
                ),
            ]
        body += ["", "\n".join(aside), ":::"]

    if guides:
        body += ["", f"## {TEXT['guides_heading']}", ""]
        body += [f"- [{escape_text(title)}]({url})" for title, url in guides]

    if package["dependencies"]:
        body += ["", f"## {TEXT['deps_heading']}", "", TEXT["deps_intro"], ""]
        body.append(
            f"| {TEXT['col_dependency']} | {TEXT['col_required']} |\n| --- | --- |"
        )
        for dep in sorted(
            package["dependencies"], key=lambda d: (d["optional"], d["name"])
        ):
            body.append(
                f"| {code(dep['name'])} | {TEXT['optional' if dep['optional'] else 'required']} |"
            )

    body += ["", f"## {TEXT['options_heading']}", ""]
    if package["options"]:
        body.append("\n\n".join(option_section(o) for o in package["options"]))
    else:
        body.append(TEXT["options_none"])
    return "\n".join(body) + "\n"


def index_page(packages: list[dict]) -> str:
    rows = [
        f"| {TEXT['col_package']} | {TEXT['col_stability']} | {TEXT['col_spelling']} | {TEXT['col_description']} |",
        "| --- | --- | --- | --- |",
    ]
    for p in sorted(packages, key=lambda p: (p["name"], p["level"])):
        rows.append(
            f"| [{p['name']}]({page_url(p)}) | {TEXT[p['level']]} | {code(p['spelling'])} "
            f"| {table_cell(escape_markdown(p['meta']['description']))} |"
        )
    return (
        "\n".join(
            [
                frontmatter(
                    {
                        "title": TEXT["index_title"],
                        "description": TEXT["index_description"],
                    }
                ),
                "",
                TEXT["index_intro"],
                "",
                TEXT["index_background"],
                "",
                *rows,
            ]
        )
        + "\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", type=pathlib.Path, required=True)
    parser.add_argument("--ledger", type=pathlib.Path, required=True)
    parser.add_argument("--guides", type=pathlib.Path, required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()

    packages = json.loads(args.data.read_text())
    for p in packages:
        if not (p["meta"]["description"] or "").strip():
            sys.exit(
                TEXT["error_no_description"].format(
                    id=p["id"], source=f"kix/packages/{p['level']}/{p['name']}"
                )
            )

    ledger = json.loads(args.ledger.read_text())
    guides = guides_by_package(ledger, args.guides, {p["id"] for p in packages})

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "index.mdx").write_text(index_page(packages))
    for p in packages:
        path = args.out / f"{page_path(p)}.mdx"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(package_page(p, guides.get(p["id"], [])))


if __name__ == "__main__":
    main()
