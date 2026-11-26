# Change records

Every change that a Kix user can see gets one file in `changes/`.

## When you need a record

If your pull request changes `cli/` or `kix/`, you must add or change a record in `changes/`. When nothing a user sees changes, add the `no-changelog` label to the pull request instead.

The Changelog workflow checks this requirement and checks every record's format.

## How to write a record

1. Create `changes/<name>.md`, usually named after your branch. Replace any `/` in the branch name with `-`, because a folder in `changes/` means a released version. Using one file per change keeps parallel branches from editing the same file.
2. Add a TOML header between `+++` lines. Set `kind` and any [header fields](#common-header-fields) that apply.
3. Write one paragraph for users below the closing `+++`. This paragraph becomes one bullet in `CHANGELOG.md`, so do not use lists or code blocks.
4. Run `scripts/change-records.py check` to validate your record.

```markdown
+++
kind = "added"
packages = ["echo-server"]
+++
`echo-server` adds a `replicas` option.
```

## Which kind to choose

For an ordinary feature, update, or bug fix, use `added`, `changed`, or `fixed`.

The `kind` picks the heading in `CHANGELOG.md`, and headings appear in `CHANGELOG.md` in the order below. See `CLAUDE.md` § Versioning and breaking changes for what counts as breaking.

| Kind | `CHANGELOG.md` heading | Breaking |
| --- | --- | --- |
| `error` | Breaking (shows an error) | yes (requires [`id`](#error-ids)) |
| `silent` | Breaking (no error) | yes |
| `note` | Upgrade notes | no |
| `security` | Security | no |
| `added` | Added | no |
| `changed` | Changed | no |
| `fixed` | Fixed | no |

## Common header fields

Only `kind` is required. The other valid fields are `packages`, `library`, and `cli` below, plus `id`, `state`, `required-stop`, `touches-data`, `cve`, and `workaround` under [Rare cases](#rare-cases). Any other field is an error.

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | string | Required. One of the values in [Which kind to choose](#which-kind-to-choose). |
| `packages` | list of strings | Packages the change touches. Use the folder name for packages under `kix/packages/stable/`, or `experimental/<name>` for packages under `kix/packages/experimental/`. Leave this field out when the change is not about particular packages. |
| `library` | list of strings | Symbols in the Kix library, such as `kix.contracts.redis`, or `kix.contracts.experimental.<name>` for an experimental contract. |
| `cli` | list of strings | `kix` commands or flags removed or changed, written as a user types them: `--old-flag`, `kix oldcmd`. |

## Rare cases

### Error IDs

A record with `kind = "error"` requires the `id` field (`string`). For other kinds, `id` is optional. Each `id` is `K` followed by four digits and must be unique across `changes/`.

```markdown
+++
kind = "error"
packages = ["echo-server", "experimental/dns-exporter"]
id = "K0001"
+++
`echo-server` and `dns-exporter` rename `replicaCount` to `replicas`. Set
`replicas` instead.
```

To add an error ID:

1. Run `scripts/change-records.py next-id` to print an ID no record uses. It picks one at random so branches worked on at the same time do not pick the same ID.
2. Set `id` in the record's TOML header.
3. Put the ID on the error that refuses the old form:
   - **In the Kix library:** set the `id` field of `scope.fail` or `kix.fail`, such as `scope.fail { id = "K0001"; message = "replicaCount was removed."; ... }`. Kix prints it as `[K0001]` at the start of the error.
   - **Elsewhere:** start the error message with the ID in brackets, such as `[K0001] ...`.

`scripts/change-records.py check` fails until a file under `kix/` or `cli/` carries the ID. People search `CHANGELOG.md` for the ID, and tools match on it.

### Experimental packages and contracts

A record is experimental when it meets all four conditions:

- Names at least one package or library symbol
- Starts every package in `packages` with `experimental/`
- Starts every symbol in `library` with `kix.contracts.experimental.`
- Sets neither `cli` nor `state`

An experimental `error` or `silent` record is listed in `CHANGELOG.md` under `Breaking in experimental packages and contracts`, after the two breaking headings. It does not raise the minor version.

### Cluster state, required stops, and stored data

| Field | Type | Allowed with | Meaning |
| --- | --- | --- | --- |
| `state` | bool | any `kind` | The change touches cluster state: Activation records, `kix.run/*` annotations, PackageInstance, or Kix's CRDs. |
| `required-stop` | bool | `state = true` | Clusters must be deployed with this release before upgrading further. This should be rare. |
| `touches-data` | bool | `kind = "silent"` | The change moves or reinterprets stored data. |

### Security records

Two optional fields apply only when `kind = "security"`:

| Field | Type | Meaning |
| --- | --- | --- |
| `cve` | list of strings | CVE IDs. |
| `workaround` | string | How to get the fix without upgrading. Leave this field out when there is no workaround, such as a fix that only a new image carries. |

## How releases use change records

At release:

- The files in `changes/` move to `changes/<version>/`.
- `CHANGELOG.md` gets a section written from them.
- Kix ships the records with each release as `kix-<version>-changes.json`.

A release with any non-experimental `error` or `silent` record raises the minor version. Otherwise, it is a patch release.

## Commands

```bash
scripts/change-records.py check                  # check every record
scripts/change-records.py next-id                # an id no record uses
scripts/change-records.py changelog              # preview the next release's section
scripts/change-records.py bump                   # minor, patch, or none
scripts/change-records.py json --version 0.10.0  # the release asset
scripts/change-records.py release 0.10.0         # used by the release skill
```

Run the unit tests with:

```bash
cd scripts && python3 -m unittest -v change_records.test_change_records
```
