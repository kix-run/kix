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
packages = ["echo-server", "dns-exporter"]
id = "K0001"
+++
`echo-server` and `dns-exporter` rename `replicaCount` to `replicas`. Set
`replicas` instead.
```

Only `kind` is required. Any field not listed here is an error.

| Field | Type | Meaning |
|---|---|---|
| `kind` | string | One of the kinds below |
| `packages` | list of strings | The packages under `kix/packages/` that the change touches. Leave it out when the change is not about particular packages |
| `library` | list of strings | Library symbols, such as `kix.contracts.redis` |
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

A release with any `error` or `silent` record raises the minor version.
Otherwise it is a patch release.

## Ids

An `error` record needs an id. The refusal the change causes starts with the
id in brackets, such as `[K0001] echo-server: ...`. Kix builds every record
into itself, and `kix explain K0001` prints the record. Run
`scripts/change-records.py next-id` on a branch that is up to date with main.
Two branches can pick the same id, and both can pass their checks. The check
then fails on main once both have merged. Give the record that merged second
the next free id, in its file and in its error message.

## Commands

```bash
scripts/change-records.py check                  # check every record
scripts/change-records.py next-id                # the next free id
scripts/change-records.py changelog              # preview the next release's section
scripts/change-records.py bump                   # minor, patch, or none
scripts/change-records.py json --version 0.10.0  # the release asset
scripts/change-records.py release 0.10.0         # used by the release skill
```

The tests: `cd scripts && python3 -m unittest -v change_records.test_change_records`.
