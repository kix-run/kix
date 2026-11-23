"""Read, check, and render the change records under `changes/`.

Each change is one Markdown file with a TOML header between `+++` lines.
`changes/<name>.md` is not released yet. `changes/<version>/<name>.md` was
released in that version. `changes/README.md` documents the format.

`scripts/change-records.py` is the command line. Other scripts import the
parser from here.
"""

from __future__ import annotations

import collections
import dataclasses
import datetime
import json
import pathlib
import random
import re
import subprocess
import tomllib

SCHEMA = "kix.run/changes/v1"
# A released version, the only name a folder under changes/ may have.
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
CHANGES_DIR = "changes"
README = "README.md"

# Kind, CHANGELOG heading, and whether it breaks, in CHANGELOG order.
KINDS: list[tuple[str, str, bool]] = [
    ("error", "Breaking (shows an error)", True),
    ("silent", "Breaking (no error)", True),
    ("note", "Upgrade notes", False),
    ("security", "Security", False),
    ("added", "Added", False),
    ("changed", "Changed", False),
    ("fixed", "Fixed", False),
]
KIND_NAMES = [kind for kind, _, _ in KINDS]
BREAKING_KINDS = {kind for kind, _, breaking in KINDS if breaking}

LIST_FIELDS = ("packages", "library", "cli", "cve")
BOOL_FIELDS = ("state", "touches-data", "required-stop")
STRING_FIELDS = ("kind", "id", "workaround")
FIELDS = set(LIST_FIELDS) | set(BOOL_FIELDS) | set(STRING_FIELDS)

# How a record names something experimental: a package as
# `experimental/<name>`, a contract as `kix.contracts.experimental.<name>`.
EXPERIMENTAL_PACKAGE = "experimental/"
EXPERIMENTAL_CONTRACT = "kix.contracts.experimental."
EXPERIMENTAL_HEADING = "Breaking in experimental packages and contracts"

ID_RE = re.compile(r"^K[0-9]{4}$")
HEADER_FENCE = "+++"


class RecordError(Exception):
    """A record, or the set of records, breaks the format."""


@dataclasses.dataclass
class Record:
    name: str
    path: pathlib.Path
    version: str | None
    kind: str
    packages: list[str]
    library: list[str]
    cli: list[str]
    state: bool
    touches_data: bool
    required_stop: bool
    id: str | None
    cve: list[str]
    workaround: str | None
    body: str

    @property
    def experimental(self) -> bool:
        """Return whether the record is only about experimental packages and contracts.

        Such a record may break in a patch release.
        """
        named = self.packages + self.library
        return (
            bool(named)
            and not self.cli
            and not self.state
            and all(p.startswith(EXPERIMENTAL_PACKAGE) for p in self.packages)
            and all(s.startswith(EXPERIMENTAL_CONTRACT) for s in self.library)
        )

    @property
    def breaks_stable(self) -> bool:
        """Return whether the record breaks something that is not experimental."""
        return self.kind in BREAKING_KINDS and not self.experimental

    def bullet(self) -> str:
        """Return the CHANGELOG bullet: the body on one line, then the id."""
        paragraphs = re.split(r"\n\s*\n", self.body.strip())
        text = " ".join(" ".join(p.split()) for p in paragraphs)
        if self.workaround:
            text += f" To get the fix without upgrading: {self.workaround.strip()}"
        if self.id:
            text += f" [{self.id}]"
        return f"- {text}"

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "kind": self.kind,
            "packages": self.packages,
            "library": self.library,
            "cli": self.cli,
            "state": self.state,
            "touchesData": self.touches_data,
            "requiredStop": self.required_stop,
            "id": self.id,
            "cve": self.cve,
            "workaround": self.workaround,
            "body": self.body,
            "experimental": self.experimental,
        }


def split_header(text: str) -> tuple[str, str]:
    """Return the TOML header and the body of a record's text."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != HEADER_FENCE:
        raise RecordError("the file must start with a `+++` line")
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == HEADER_FENCE:
            return "".join(lines[1:i]), "".join(lines[i + 1 :])
    raise RecordError("the header has no closing `+++` line")


def parse_record(path: pathlib.Path, text: str, version: str | None = None) -> Record:
    """Parse one record and check its fields. Raise RecordError listing every problem."""
    header_text, body = split_header(text)
    try:
        header = tomllib.loads(header_text)
    except tomllib.TOMLDecodeError as e:
        raise RecordError(f"the header is not valid TOML: {e}") from None

    problems: list[str] = []
    for key in sorted(set(header) - FIELDS):
        problems.append(
            f"unknown field `{key}`. The fields are: {', '.join(sorted(FIELDS))}"
        )
    for key in LIST_FIELDS:
        value = header.get(key, [])
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            problems.append(f"`{key}` must be a list of strings")
    for key in BOOL_FIELDS:
        if not isinstance(header.get(key, False), bool):
            problems.append(f"`{key}` must be true or false")
    for key in STRING_FIELDS:
        if key in header and not isinstance(header[key], str):
            problems.append(f"`{key}` must be a string")

    kind = header.get("kind")
    if kind is None:
        problems.append(f"`kind` is required. Use one of: {', '.join(KIND_NAMES)}")
    elif isinstance(kind, str) and kind not in KIND_NAMES:
        problems.append(
            f'`kind = "{kind}"` is unknown. Use one of: {", ".join(KIND_NAMES)}'
        )

    record_id = header.get("id")
    if isinstance(record_id, str) and not ID_RE.match(record_id):
        problems.append(
            f'`id = "{record_id}"` must be K and four digits, such as K0001'
        )
    if kind == "error" and record_id is None:
        problems.append(
            '`kind = "error"` needs an `id`. Run `scripts/change-records.py next-id` to get one'
        )
    if header.get("touches-data") is True and kind != "silent":
        problems.append('`touches-data` is only for `kind = "silent"`')
    if header.get("required-stop") is True and header.get("state") is not True:
        problems.append("`required-stop` needs `state = true`")
    if header.get("cve") and kind != "security":
        problems.append('`cve` is only for `kind = "security"`')
    if kind == "security":
        workaround = header.get("workaround")
        if "workaround" in header and (
            not isinstance(workaround, str) or not workaround.strip()
        ):
            problems.append(
                "`workaround` must say how to get the fix without upgrading. Leave it out when there is no workaround"
            )
    elif "workaround" in header:
        problems.append('`workaround` is only for `kind = "security"`')
    if not body.strip():
        problems.append(
            "the text below the header is empty. Describe the change for users"
        )
    elif any(
        line.lstrip().startswith(("- ", "* ", "```")) for line in body.splitlines()
    ):
        problems.append(
            "the text must be plain paragraphs, with no list or code block. "
            "It becomes one bullet in CHANGELOG.md"
        )

    if problems:
        raise RecordError("; ".join(problems))

    def strings(key: str) -> list[str]:
        return list(header.get(key, []))

    return Record(
        name=path.stem,
        path=path,
        version=version,
        kind=kind,
        packages=strings("packages"),
        library=strings("library"),
        cli=strings("cli"),
        state=header.get("state", False),
        touches_data=header.get("touches-data", False),
        required_stop=header.get("required-stop", False),
        id=record_id,
        cve=strings("cve"),
        workaround=header.get("workaround"),
        body=body.strip() + "\n",
    )


def record_paths(root: pathlib.Path) -> list[tuple[pathlib.Path, str | None]]:
    """Return every record file under `changes/` with its release version, or None."""
    changes = root / CHANGES_DIR
    if not changes.is_dir():
        return []
    found: list[tuple[pathlib.Path, str | None]] = []
    for entry in sorted(changes.iterdir()):
        if entry.is_dir():
            found.extend((p, entry.name) for p in sorted(entry.glob("*.md")))
        elif entry.suffix == ".md" and entry.name != README:
            found.append((entry, None))
    return found


# An id as an error carries it: in brackets in a message, such as `[K0001]`,
# as the `id` field of a `kix.fail` error, such as `id = "K0001";`, or as the
# `id` field of a Rust struct, such as `id: "K0001",`.
ID_IN_SOURCE_RE = re.compile(r'\[(K\d{4})\]|\bid\s*[=:]\s*"\[?(K\d{4})\]?"')


def ids_in_source(root: pathlib.Path) -> set[str]:
    """Return every id an error carries in Nix, Rust, and TOML files under kix/ and cli/."""
    found: set[str] = set()
    for top in ("kix", "cli"):
        for path in (root / top).rglob("*"):
            if path.suffix not in (".nix", ".rs", ".toml") or not path.is_file():
                continue
            try:
                for bracketed, field in ID_IN_SOURCE_RE.findall(path.read_text()):
                    found.add(bracketed or field)
            except (OSError, UnicodeDecodeError):
                continue
    return found


def removed_packages(packages_dir: pathlib.Path) -> set[str]:
    """Return the packages `kix/packages/removed.toml` names, as a record names them."""
    path = packages_dir / "removed.toml"
    if not path.is_file():
        return set()
    return set(tomllib.loads(path.read_text()))


def load(root: pathlib.Path) -> tuple[list[Record], list[str]]:
    """Read every record. Return the records that parse and a list of problems."""
    records: list[Record] = []
    problems: list[str] = []
    changes = root / CHANGES_DIR
    for entry in sorted(changes.iterdir()) if changes.is_dir() else []:
        if entry.is_dir() and not VERSION_RE.fullmatch(entry.name):
            problems.append(
                f"{entry.relative_to(root)}/: a folder under changes/ must be a released "
                "version such as 0.10.0. Put a new record directly in changes/, and "
                "replace any `/` in its name"
            )
    for path, version in record_paths(root):
        rel = path.relative_to(root)
        try:
            records.append(parse_record(path, path.read_text(), version))
        except RecordError as e:
            problems.append(f"{rel}: {e}")
    packages_dir = root / "kix" / "packages"
    if packages_dir.is_dir():
        removed = removed_packages(packages_dir)
        for record in records:
            if record.version is not None:
                continue
            for name in record.packages:
                if name in removed:
                    continue
                level, folder = (
                    ("experimental", name.removeprefix(EXPERIMENTAL_PACKAGE))
                    if name.startswith(EXPERIMENTAL_PACKAGE)
                    else ("stable", name)
                )
                if not (packages_dir / level / folder).is_dir():
                    problems.append(
                        f"{record.path.relative_to(root)}: `{name}` in `packages` is not a "
                        f"folder under kix/packages/{level}/. Use the package's folder name, "
                        f"with `{EXPERIMENTAL_PACKAGE}` before it for an experimental package"
                    )
    # An `error` record describes a refusal, and the refusal prints the id.
    # Released records are not checked: their refusals are removed later.
    pending = [r for r in records if r.version is None and r.kind == "error" and r.id]
    if pending and (root / "kix").is_dir():
        printed = ids_in_source(root)
        for record in pending:
            if record.id not in printed:
                problems.append(
                    f"{record.path.relative_to(root)}: no file under kix/ or cli/ prints "
                    f"[{record.id}]. Give the error that refuses the old form the id: "
                    f'`kix.fail {{ id = "{record.id}"; ... }}`, or start its message with [{record.id}]'
                )
    seen: dict[str, pathlib.Path] = {}
    for record in records:
        if record.id is None:
            continue
        if record.id in seen:
            problems.append(
                f"{record.path.relative_to(root)}: id {record.id} is also used by "
                f"{seen[record.id].relative_to(root)}. Run `scripts/change-records.py next-id` "
                "and renumber the newer record"
            )
        else:
            seen[record.id] = record.path
    return records, problems


def load_valid(root: pathlib.Path) -> list[Record]:
    """Read every record, and raise RecordError when any breaks the format."""
    records, problems = load(root)
    if problems:
        raise RecordError("\n".join(problems))
    return records


def unreleased(records: list[Record]) -> list[Record]:
    return sorted((r for r in records if r.version is None), key=lambda r: r.name)


def released(records: list[Record], version: str) -> list[Record]:
    return sorted((r for r in records if r.version == version), key=lambda r: r.name)


def select(records: list[Record], version: str | None) -> list[Record]:
    """Return the records released in `version` when that folder has any, else the unreleased ones."""
    if version is not None:
        chosen = released(records, version)
        if chosen:
            return chosen
    return unreleased(records)


def next_id(records: list[Record]) -> str:
    """Return an id no record uses, picked at random.

    Branches worked on at the same time each pick an id before either
    merges. Counting up would give them the same one.
    """
    used = {r.id for r in records if r.id}
    free = [f"K{n:04d}" for n in range(1, 10000) if f"K{n:04d}" not in used]
    return random.choice(free)


def bump(records: list[Record]) -> str:
    """Return `minor`, `patch`, or `none` for the unreleased records."""
    pending = unreleased(records)
    if not pending:
        return "none"
    if any(r.breaks_stable for r in pending):
        return "minor"
    return "patch"


def changelog(
    records: list[Record], version: str | None = None, date: str | None = None
) -> str:
    """Return the CHANGELOG section for `records`, with a `## ` heading when given a version and date."""
    out: list[str] = []
    if version is not None and date is not None:
        out += [f"## {version} - {date}", ""]
    for kind, heading, breaking in KINDS:
        bullets = [
            r.bullet()
            for r in records
            if r.kind == kind and not (breaking and r.experimental)
        ]
        if bullets:
            out += [f"### {heading}", "", *bullets, ""]
        if kind == "silent":
            # After the breaking headings, in the order error then silent.
            bullets = [
                r.bullet()
                for k in ("error", "silent")
                for r in records
                if r.kind == k and r.experimental
            ]
            if bullets:
                out += [f"### {EXPERIMENTAL_HEADING}", "", *bullets, ""]
    return "\n".join(out)


def to_json(records: list[Record], version: str) -> dict:
    return {
        "schema": SCHEMA,
        "version": version,
        "records": [r.to_json() for r in records],
    }


def release(root: pathlib.Path, version: str, date: str | None = None) -> list[Record]:
    """Move the unreleased records into `changes/<version>/` and add their section to CHANGELOG.md."""
    if not VERSION_RE.fullmatch(version):
        raise RecordError(
            f"`{version}` is not a release version. Give it as X.Y.Z, such as 0.10.0. "
            "A prerelease moves no records"
        )
    records = load_valid(root)
    pending = unreleased(records)
    if not pending:
        raise RecordError(
            "there are no unreleased records under changes/, so there is nothing to release"
        )
    target = root / CHANGES_DIR / version
    if target.exists():
        raise RecordError(f"{target.relative_to(root)} already exists")
    date = date or datetime.date.today().isoformat()

    changelog_path = root / "CHANGELOG.md"
    lines = changelog_path.read_text().splitlines(keepends=True)
    at = next((i for i, line in enumerate(lines) if line.startswith("## ")), len(lines))
    section = changelog(pending, version, date)
    lines[at:at] = [section + "\n"]

    target.mkdir()
    for record in pending:
        record.path.rename(target / record.path.name)
        record.path = target / record.path.name
        record.version = version
    changelog_path.write_text("".join(lines))
    return pending


RECORD_EXAMPLE = """\
    +++
    kind = "fixed"            # error, silent, note, security, added, changed, or fixed
    packages = ["caddy"]      # the packages it touches, if any
    +++
    `caddy` now starts when ...
"""


def git(root: pathlib.Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout


def pr_problems(
    root: pathlib.Path, base: str, head: str, record_required: bool = True
) -> list[str]:
    """Return what a pull request from `base` to `head` is missing for the change-record rules."""
    status = git(root, "diff", "--name-status", "--no-renames", f"{base}...{head}")
    changes = [line.split("\t", 1) for line in status.splitlines() if line]
    paths = [path for _, path in changes]

    unreleased_re = re.compile(rf"^{CHANGES_DIR}/(?!{re.escape(README)}$)[^/]+\.md$")
    released_re = re.compile(rf"^{CHANGES_DIR}/\d+\.\d+\.\d+/[^/]+\.md$")
    adds_record = any(s[0] in "AM" and unreleased_re.match(p) for s, p in changes)
    touches_code = any(p.startswith(("cli/", "kix/")) for p in paths)

    # A version folder that exists at the base is a release that shipped.
    # Its records also went out as kix-<version>-changes.json, so they stay
    # as they are. A folder new in this pull request is the release itself.
    merge_base = git(root, "merge-base", base, head).strip()
    shipped: set[str] = set()
    new_folders: set[str] = set()
    for _, path in changes:
        if released_re.match(path):
            folder = path.rsplit("/", 1)[0]
            if git(root, "ls-tree", merge_base, f"{folder}/").strip():
                shipped.add(folder)
            else:
                new_folders.add(folder)
    is_release = bool(new_folders)

    problems: list[str] = []
    for folder in sorted(shipped):
        problems.append(
            f"This pull request changes records in {folder}/, a release that has shipped.\n"
            "Released records do not change. Put a new record directly in changes/."
        )
    if record_required and touches_code and not adds_record and not is_release:
        problems.append(
            "This pull request changes cli/ or kix/ and adds no change record.\n"
            "Add a file changes/<name>.md, usually named after the branch, such as:\n\n"
            f"{RECORD_EXAMPLE}\n"
            "changes/README.md lists the kinds and fields. If nothing a Kix user sees changes,\n"
            "label the pull request no-changelog instead."
        )

    if not is_release and "CHANGELOG.md" in paths:
        before = release_lines(show(root, merge_base, "CHANGELOG.md"))
        after = release_lines(show(root, head, "CHANGELOG.md"))
        if after - before:
            problems.append(
                "This pull request adds lines to the release sections of CHANGELOG.md.\n"
                "Kix writes those sections from the change records when it is released.\n"
                "Put the entry in a change record, changes/<name>.md, instead\n"
                "(changes/README.md has the format)."
            )
    return problems


def show(root: pathlib.Path, rev: str, path: str) -> str:
    """Return a file's text at `rev`, or an empty string when it does not exist there."""
    result = subprocess.run(
        ["git", "show", f"{rev}:{path}"], cwd=root, capture_output=True, text=True
    )
    return result.stdout if result.returncode == 0 else ""


def release_lines(text: str) -> collections.Counter[str]:
    """Count the non-blank lines from the first `## ` heading on. The intro above it is free text."""
    lines = text.splitlines()
    at = next((i for i, line in enumerate(lines) if line.startswith("## ")), len(lines))
    return collections.Counter(line for line in lines[at:] if line.strip())
