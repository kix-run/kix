# Change records

Every change that a Kix user can see gets its own file in `changes/`, so parallel branches never edit the same file.

## When you need a record

If your pull request changes `cli/` or `kix/`, add or update a record in `changes/`. If nothing a user sees changes (for example, tests or an internal refactor), add the `no-changelog` label to the pull request instead.

The Changelog workflow checks this rule and validates every record's format.

## How to write a record

1. Create `changes/<name>.md`, usually named after your branch. Replace any `/` in the branch name with `-`, because folders in `changes/` hold released versions.
2. Add a TOML header between `+++` lines. Set [`kind`](#which-kind-to-choose) and any [other fields](#common-header-fields) that apply.
3. Below the closing `+++`, write one paragraph for users describing what changed (and what to update, if anything). Because it becomes a single bullet in `CHANGELOG.md`, do not use lists or code blocks.
4. Run `scripts/change-records.py check` to validate your record.

```markdown
+++
kind = "added"
packages = ["echo-server"]
+++
`echo-server` adds a `replicas` option.
```

## Which kind to choose

Most changes use `added`, `changed`, or `fixed`. Use `error` when Kix stops with an error that tells the user what to change, `silent` when a breaking change produces no error, and `note` when users should know about a change that needs no action (for example, pods restart once). For full rules on what counts as breaking, see `CLAUDE.md` § Versioning and breaking changes.

Each `kind` maps to a heading in `CHANGELOG.md`, in the order below:

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

Every record requires `kind` (and `kind = "error"` also requires [`id`](#error-ids)). All other fields are optional, and unknown fields fail validation. For `id`, `state`, `required-stop`, `touches-data`, `cve`, and `workaround`, see [Rare cases](#rare-cases).

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | string | Required. One of the values in [Which kind to choose](#which-kind-to-choose). |
| `packages` | list of strings | Packages the change affects: `<name>` for a package in `kix/packages/stable/`, or `experimental/<name>` for one in `kix/packages/experimental/`. Leave this out when the change is not about particular packages. |
| `library` | list of strings | Symbols in the Kix library, such as `kix.contracts.redis`, or `kix.contracts.experimental.<name>` for an experimental contract. |
| `cli` | list of strings | `kix` commands or flags removed or changed, written as a user types them: `--old-flag`, `kix oldcmd`. |

## Rare cases

### Error IDs

A record with `kind = "error"` requires an `id` (`string`), such as `"K0001"`. People look up the ID in `CHANGELOG.md`, and tools match on it. For other kinds, `id` is optional. Each `id` is `K` followed by four digits and must be unique across `changes/`.

```markdown
+++
kind = "error"
packages = ["echo-server", "experimental/dns-exporter"]
id = "K0001"
+++
Replace `replicaCount` with `replicas` in `echo-server` and `dns-exporter`.
Both packages renamed `replicaCount` to `replicas`.
```

To add an error ID:

1. Run `scripts/change-records.py next-id` to get an unused ID. It picks one at random so parallel branches do not choose the same ID.
2. Set `id` in the record's TOML header.
3. Attach the ID to the error that refuses the old form:
   - **In the Kix library and packages:** set `id` on `scope.fail`, `kix.fail`, or `kix/packages/removed.toml` (for example, `scope.fail { id = "K0001"; message = "replicaCount was removed."; ... }`). Kix prints `[K0001]` at the start of the error.
   - **Elsewhere in `kix/` or `cli/`:** set the refusal struct's `id` field, or start the error message with `[K0001]`.

For unreleased `error` records, `scripts/change-records.py check` fails until a file under `kix/` or `cli/` includes the ID.

### Experimental packages and contracts

A record counts as experimental when all four conditions hold:

- `packages` or `library` lists at least one entry.
- Every entry in `packages` starts with `experimental/`.
- Every entry in `library` starts with `kix.contracts.experimental.`.
- Neither `cli` nor `state` is set.

An experimental `error` or `silent` record is listed in `CHANGELOG.md` under `Breaking in experimental packages and contracts`, after the two breaking headings. It does not raise the minor version.

### Cluster state, required stops, and stored data

| Field | Type | Allowed with | Meaning |
| --- | --- | --- | --- |
| `state` | bool | any `kind` | The change touches cluster state: Activation records, `kix.run/*` annotations, PackageInstance, or Kix's CRDs. |
| `required-stop` | bool | `state = true` | Clusters must deploy this release before upgrading further. This should be rare. |
| `touches-data` | bool | `kind = "silent"` | The change moves or reinterprets stored data. |

### Security records

Two optional fields apply only when `kind = "security"`:

| Field | Type | Meaning |
| --- | --- | --- |
| `cve` | list of strings | CVE IDs. |
| `workaround` | string | How to get the fix without upgrading (appended to the changelog bullet after `To get the fix without upgrading:`). Leave this out when there is no workaround, such as a fix that requires a new image. |

## How releases use change records

At release:

- Unreleased records in `changes/` move to `changes/<version>/`.
- Their entries are added as a new section in `CHANGELOG.md`.
- Each release publishes the records as `kix-<version>-changes.json`, which `kix upgrade` reads.

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
