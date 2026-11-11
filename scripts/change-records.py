#!/usr/bin/env python3
"""Check the change records under `changes/` and write the changelog from them.

    scripts/change-records.py check                       # every record's format
    scripts/change-records.py check --base A --head B     # and the pull request rules
    scripts/change-records.py next-id                     # the next free id, such as K0003
    scripts/change-records.py bump                        # minor, patch, or none
    scripts/change-records.py changelog [--version V --date D]
    scripts/change-records.py json [--version V]
    scripts/change-records.py release V [--date D]

The format and the kinds are in `changes/README.md`. The logic lives in
`scripts/change_records/`, which other scripts import.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import change_records as cr  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root", type=pathlib.Path, default=ROOT, help=argparse.SUPPRESS
    )
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser(
        "check",
        help="check every record, and with --base/--head the pull request rules",
    )
    check.add_argument("--base")
    check.add_argument("--head")
    check.add_argument(
        "--no-record-required",
        action="store_true",
        help="skip the rule that a change to cli/ or kix/ adds a record (the no-changelog label)",
    )
    sub.add_parser("next-id", help="print the next free id")
    sub.add_parser(
        "bump", help="print minor, patch, or none for the unreleased records"
    )
    changelog = sub.add_parser("changelog", help="print the CHANGELOG section")
    changelog.add_argument("--version")
    changelog.add_argument("--date")
    as_json = sub.add_parser("json", help="print the records as JSON")
    as_json.add_argument("--version")
    release = sub.add_parser(
        "release", help="move the unreleased records into changes/<version>/"
    )
    release.add_argument("version")
    release.add_argument("--date")

    args = parser.parse_args(argv)
    root: pathlib.Path = args.root

    if args.command == "check":
        if (args.base is None) != (args.head is None):
            parser.error("--base and --head go together")
        records, problems = cr.load(root)
        if args.base:
            problems += cr.pr_problems(
                root, args.base, args.head, not args.no_record_required
            )
        for problem in problems:
            print(problem, file=sys.stderr)
        if problems:
            return 1
        print(
            f"{len(records)} change records, {len(cr.unreleased(records))} unreleased"
        )
        return 0

    try:
        if args.command == "release":
            moved = cr.release(root, args.version, args.date)
            print(
                f"Moved {len(moved)} records to changes/{args.version}/ and updated CHANGELOG.md."
            )
            return 0
        records = cr.load_valid(root)
    except cr.RecordError as e:
        print(e, file=sys.stderr)
        return 1

    if args.command == "next-id":
        print(cr.next_id(records))
    elif args.command == "bump":
        print(cr.bump(records))
    elif args.command == "changelog":
        if args.date and not args.version:
            parser.error("--date needs --version")
        print(
            cr.changelog(cr.select(records, args.version), args.version, args.date),
            end="",
        )
    elif args.command == "json":
        version = args.version or "unreleased"
        print(
            json.dumps(cr.to_json(cr.select(records, args.version), version), indent=2)
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
