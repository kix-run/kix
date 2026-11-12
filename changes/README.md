# Change records

Each change that a Kix user can see gets one file here, usually named after
the branch: `changes/<name>.md`. Replace any `/` in the branch name with `-`,
because a folder here means a released version. A file per change means
parallel branches never edit the same file. At release, the files move to
`changes/<version>/`, and `CHANGELOG.md` gets a section written from them.
Kix also ships them with each release as `kix-<version>-changes.json`.

A pull request that changes `cli/` or `kix/` must add or change a record,
unless it has the `no-changelog` label because nothing a user sees changes.
The Changelog workflow checks this, and checks every record's format.

## Format

A TOML header between `+++` lines, then one paragraph for users. The
paragraph becomes one bullet in `CHANGELOG.md`, so it takes no list and no
code block.

```markdown
+++
kind = "error"
packages = ["echo-server", "experimental/dns-exporter"]
id = "K0001"
+++
`echo-server` and `dns-exporter` rename `replicaCount` to `replicas`. Set
`replicas` instead.
```

Only `kind` is required. Any field not listed here is an error.

| Field | Type | Meaning |
|---|---|---|
| `kind` | string | One of the kinds below |
| `packages` | list of strings | The packages the change touches: a folder name under `kix/packages/stable/`, or `experimental/<name>` for a folder under `kix/packages/experimental/`. Leave it out when the change is not about particular packages |
| `library` | list of strings | Library symbols, such as `kix.contracts.redis`. An experimental contract is `kix.contracts.experimental.<name>` |
| `cli` | list of strings | CLI commands or flags removed or changed, as a user types them: `--old-flag`, `kix oldcmd` |
| `state` | bool | The change touches cluster state: Activation records, `kix.run/*` annotations, PackageInstance, or Kix's CRDs |
| `touches-data` | bool | The change moves or reinterprets stored data. Only with `kind = "silent"` |
| `required-stop` | bool | Clusters must be deployed with this release before upgrading further. Only with `state = true`. This should be rare |
| `id` | string | `K` and four digits. Required for `kind = "error"`, optional otherwise. Unique across `changes/` |
| `cve` | list of strings | CVE ids. Only with `kind = "security"` |
| `workaround` | string | How to get the fix without upgrading. Required for `kind = "security"` |

## Kinds

The kind picks the `CHANGELOG.md` heading. Headings appear in this order.
`CLAUDE.md` § Versioning and breaking changes says what counts as breaking.

| Kind | Heading | Breaking |
|---|---|---|
| `error` | Breaking (shows an error) | yes |
| `silent` | Breaking (no error) | yes |
| `note` | Upgrade notes | no |
| `security` | Security | no |
| `added` | Added | no |
| `changed` | Changed | no |
| `fixed` | Fixed | no |

A record is experimental when it names at least one package or library
symbol, every package it names starts with `experimental/`, every library
symbol starts with `kix.contracts.experimental.`, and it sets neither `cli`
nor `state`. An experimental `error` or `silent` record is listed under
"Breaking in experimental packages and contracts", after the two breaking
headings, and does not raise the minor version.

A release with any other `error` or `silent` record raises the minor version.
Otherwise it is a patch release.

## Ids

An `error` record needs an id, and the refusal starts with it in brackets,
such as `[K0001]`. People search CHANGELOG.md for the id, and tools match it. `scripts/change-records.py next-id` prints
an id no record uses. It picks one at random, so that branches worked on at
the same time do not pick the same id.

The error that refuses the old form starts with the id in brackets, such as
`[K0001] caddy: ...`. The check fails until a file under `kix/` or `cli/`
prints it. People search `CHANGELOG.md` for the id, and tools match on it.

## Commands

```bash
scripts/change-records.py check                  # check every record
scripts/change-records.py next-id                # an id no record uses
scripts/change-records.py changelog              # preview the next release's section
scripts/change-records.py bump                   # minor, patch, or none
scripts/change-records.py json --version 0.10.0  # the release asset
scripts/change-records.py release 0.10.0         # used by the release skill
```

The tests: `cd scripts && python3 -m unittest -v change_records.test_change_records`.
