#!/usr/bin/env python3
"""Write the licence texts and the LGPL sources of the Kix runtime.

Usage: legal.py <components.json> <out-dir>

<components.json> is the `components` list from runtime.nix. This script
writes:

  <out-dir>/THIRD_PARTY_LICENSES   every component, its licence, where its
                                   source is, and the licence and NOTICE
                                   files from that source
  <out-dir>/sources/<name>-<ver>/  the exact source of each LGPL component,
                                   with the patches nixpkgs applies to it

runtime.nix has already refused any licence that is not on the approved list.
This script checks that the licence file of each upstream program says what
runtime.nix declares.

Nix runs this script in a build with no network. It needs GNU tar and the
decompressors for the source archives on PATH.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

LICENCE_FILE = re.compile(
    r"^(licen[cs]e|copying|notice|copyright|unlicense)([._-][\w.-]*)?$", re.IGNORECASE
)
MAX_LICENCE_BYTES = 512 * 1024

# Text that a licence file must contain for each licence runtime.nix may
# declare for an upstream program.
MARKERS = {
    "Apache-2.0": ["Apache License", "Version 2.0, January 2004"],
    "MPL-2.0": ["Mozilla Public License Version 2.0"],
}

HEADER = """\
Third-party software in the Kix runtime

Kix starts each program below as a separate process and links none of them.
This file lists each program and every library built into it, with its
licence, where its source is, and the licence and NOTICE files from that
source.

The source of every component under the LGPL, with the patches nixpkgs
applies to it, is in kix-<version>-third-party-sources.tar.zst, attached to
each release at https://github.com/kix-run/kix-releases. To run Kix with your
own build of a component, point KIX_RUNTIME_DIR at a runtime directory that
holds it.
"""


def is_lgpl(component):
    return any(l.startswith("LGPL-") for l in component["licences"])


# Directories, relative to the top of a source, that may hold the licence
# files when the top holds none.
LICENCE_DIRS = ["", "doc", "docs", "LICENSES", "licenses"]


def licence_files_in_dir(src):
    for sub in LICENCE_DIRS:
        base = os.path.join(src, sub)
        if not os.path.isdir(base):
            continue
        found = []
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if LICENCE_FILE.match(name) and os.path.isfile(path):
                found.append((os.path.join(sub, name), path))
        if found:
            return found
    return []


def read_text(path):
    with open(path, "rb") as f:
        data = f.read(MAX_LICENCE_BYTES + 1)
    if len(data) > MAX_LICENCE_BYTES:
        return None
    return data.decode("utf-8", errors="replace")


def licence_texts_in_archive(src, scratch):
    """Return (name, text) for each licence file at the top of archive `src`.

    The top is the archive root, or the one directory every member sits in.
    """
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            members = z.namelist()
            wanted = top_level_licence_members(members)
            return [(os.path.basename(m), z.read(m).decode("utf-8", errors="replace")) for m in wanted]
    listing = subprocess.run(["tar", "-tf", src], check=True, capture_output=True, text=True)
    members = listing.stdout.splitlines()
    wanted = top_level_licence_members(members)
    if not wanted:
        return []
    out = tempfile.mkdtemp(dir=scratch)
    subprocess.run(["tar", "-xf", src, "-C", out, "--", *wanted], check=True)
    texts = []
    for m in wanted:
        text = read_text(os.path.join(out, m))
        if text is not None:
            texts.append((os.path.basename(m), text))
    return texts


def top_level_licence_members(members):
    """Return the members of an archive listing that are licence files.

    They sit at the top of the source, which is the archive root or the one
    directory everything else is in, or in one of LICENCE_DIRS below it.
    """
    def clean(m):
        m = m[2:] if m.startswith("./") else m
        return m.rstrip("/")

    names = {clean(m): m for m in members if clean(m)}
    tops = {n.split("/", 1)[0] for n in names}
    top = next(iter(tops)) if len(tops) == 1 else None
    prefix = top + "/" if top is not None and any(n.startswith(top + "/") for n in names) else ""
    for sub in LICENCE_DIRS:
        base = prefix + (sub + "/" if sub else "")
        wanted = []
        for name, member in names.items():
            rest = name[len(base):] if name.startswith(base) else None
            if rest and "/" not in rest and LICENCE_FILE.match(rest) and not member.endswith("/"):
                wanted.append(member)
        if wanted:
            return sorted(wanted)
    return []


def licence_texts(component, scratch):
    if component.get("licenceFiles"):
        texts = []
        for path in component["licenceFiles"]:
            text = read_text(path)
            if text is None:
                sys.exit(f"{path} is too large to be a licence file")
            texts.append(("LICENSE", text))
        return texts
    src = component.get("src")
    if not src:
        return []
    if os.path.isdir(src):
        texts = []
        for name, path in licence_files_in_dir(src):
            text = read_text(path)
            if text is not None:
                texts.append((name, text))
        return texts
    return licence_texts_in_archive(src, scratch)


def check_declared(component, texts):
    """Fail when an upstream program's licence file does not match runtime.nix."""
    if not component.get("licenceFiles"):
        return
    body = "\n".join(t for _, t in texts)
    for licence in component["licences"]:
        markers = MARKERS.get(licence)
        if markers is None:
            sys.exit(
                f"legal.py cannot check that {component['name']}'s licence file is {licence}. "
                "Add the text that identifies it to MARKERS."
            )
        missing = [m for m in markers if m not in body]
        if missing:
            sys.exit(
                f"runtime.nix declares {licence} for {component['name']} {component['version']}, "
                f"but its licence file does not contain {missing}"
            )


def source_dir_name(component):
    return f"{component['name']}-{component['version']}" if component["version"] else component["name"]


def copy_source(component, dest):
    os.makedirs(dest)
    src = component["src"]
    if os.path.isdir(src):
        shutil.copytree(src, os.path.join(dest, "source"), symlinks=True)
    else:
        shutil.copyfile(src, os.path.join(dest, strip_hash(os.path.basename(src))))
    if component["patches"]:
        patches = os.path.join(dest, "patches")
        os.makedirs(patches)
        for i, patch in enumerate(component["patches"], 1):
            target = os.path.join(patches, f"{i:02d}-{strip_hash(os.path.basename(patch))}")
            if os.path.isdir(patch):
                shutil.copytree(patch, target, symlinks=True)
            else:
                shutil.copyfile(patch, target)


def strip_hash(store_name):
    """Return a store file name without its hash prefix."""
    m = re.match(r"^[0-9a-z]{32}-(.*)$", store_name)
    return m.group(1) if m else store_name


def entry(component, texts, source_in_archive):
    lines = [
        "=" * 78,
        f"{component['name']} {component['version']}".rstrip(),
        "=" * 78,
        f"Part of: {component['program']}",
        f"Licence: {' AND '.join(component['licences'])}",
    ]
    if component.get("homepage"):
        lines.append(f"Homepage: {component['homepage']}")
    if component.get("source"):
        lines.append(f"Source: {component['source']}")
    if component.get("download"):
        hash_note = f" ({component['downloadHash']})" if component.get("downloadHash") else ""
        lines.append(f"Downloaded from: {component['download']}{hash_note}")
    if source_in_archive:
        lines.append(f"Source in the sources archive: {source_in_archive}/")
    lines.append("")
    if not texts:
        lines.append("The source carries no licence file. The licence above applies.")
        lines.append("")
    for name, text in texts:
        lines.append(f"--- {name} ---")
        lines.append(text.rstrip("\n"))
        lines.append("")
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        components = json.load(f)
    out = sys.argv[2]
    os.makedirs(os.path.join(out, "sources"))
    scratch = tempfile.mkdtemp()

    copied = {}  # src store path -> directory in the sources archive
    parts = [HEADER]
    without_texts = []
    for c in sorted(components, key=lambda c: (c["program"], c["name"], c["version"])):
        texts = licence_texts(c, scratch)
        check_declared(c, texts)
        if not texts:
            without_texts.append(f"{c['name']} {c['version']}")
        in_archive = None
        if is_lgpl(c):
            if not c.get("src"):
                sys.exit(f"{c['name']} is under the LGPL, but runtime.nix gives no source for it")
            in_archive = copied.get(c["src"])
            if in_archive is None:
                in_archive = source_dir_name(c)
                copy_source(c, os.path.join(out, "sources", in_archive))
                copied[c["src"]] = in_archive
        parts.append(entry(c, texts, in_archive))

    with open(os.path.join(out, "THIRD_PARTY_LICENSES"), "w") as f:
        f.write("\n".join(parts))
    shutil.rmtree(scratch)
    print(f"wrote licences for {len(components)} components and the sources of {len(copied)}")
    if without_texts:
        print("no licence file found in the source of: " + ", ".join(without_texts))


if __name__ == "__main__":
    main()
