# 166: Contracts as a first-class part of Kix

**Status:** Implemented (branch `package-levels`, Kix 0.10.0, 2026-11-11). Open items are in `ROADMAP.md § Open design questions`.
**Related:** `165_package_and_contract_levels.md` (the stable and experimental levels), `148_clickhouse_packages_plan.md` (two packages behind one contract)

## Context

A contract says what a package publishes for other packages to read. The
Redis contract names `host`, `port`, `credentials`, `tls`, and `sentinel`.
`valkey` publishes those fields, `harbor` reads them, and a `kix.mkImport`
can publish them for a server outside the cluster.

Kix has eight contracts, all built with one function, `mkContract`
(`kix/lib/vocab/contract.nix`). They are kept in two kinds of place, and
neither fits.

- **Seven live in the library**, in `kix/lib/vocab/`, beside unrelated
  helpers for mounts, durations, and quantities. The library is machinery. A
  contract is content that changes when packages change, and adding one
  should not mean editing the library.
- **One lives in a package.** The ClickHouse contract is
  `kix/packages/clickhouse/contract.nix`. `clickhouse-cluster` and
  `clickhouse-database` import it by relative path, and it is the only
  contract that is not under `kix.contracts`. A package is one
  implementation of a contract, and this contract has two.

Doc 165 gives contracts a stability level of their own, so they also need a
place where that level can show.

## Decision

### Contracts get their own folder

```
kix/
  lib/                    machinery, including mkContract
  contracts/
    stable/
      redis.nix
      smtp.nix
    experimental/
      clickhouse.nix
  packages/
    stable/
    experimental/
```

- A stable contract is `kix.contracts.redis`, as today.
- An experimental contract is `kix.contracts.experimental.clickhouse`.
- `kix.contracts.stable.redis` is the same contract as `kix.contracts.redis`,
  to match `packages.stable`.
- The folder listing is the registration. Adding a contract is adding a
  file. The file name is the name under `kix.contracts`, so
  `postgres-database.nix` becomes `postgresDatabase.nix`.
- No contract can be named `stable` or `experimental`.

Five contracts are stable (`gateway`, `oidc`, `postgresDatabase`, `redis`,
`smtp`) and three experimental (`clickhouse`, `oidcProvider`,
`otlpEndpoint`). Doc 165, step 3, gives the reason.

### One shape for every contract

What differs between the eight contracts today:

| Difference | Today |
|---|---|
| Where it lives | Seven in `kix/lib/vocab/`, one in a package folder |
| How it is reached | Seven under `kix.contracts.*`, one by file path |
| The dependency name readers take it under | Redis is taken as `valkey`, which names one implementation |
| Helpers beside the checks | `oidc` adds `client`, `smtp` adds `server` and `settings`, `gateway` adds `claims`, `redis` adds `usesSentinel` |
| Options that go with a contract | `oidc` and `smtp` attach theirs under `kix.options.oidc` and `kix.options.mail` |

Every contract file returns the same top-level keys:

| Key | Meaning |
|---|---|
| `name` | The name used in messages, such as "Redis" |
| `alias` | The dependency name a reader takes it under |
| `fields` | The field table: `required`, `shape`, and `test` for each field |
| `check`, `problems`, `assertions`, `require` | The validators `mkContract` builds |
| `helpers` | Functions for readers, such as `usesSentinel` |
| `options` | Option sets a reader adds to its own options, when the contract has any |

A contract file passes `helpers` and `options` to `mkContract` and returns
its result unchanged:

```nix
mkContract {
  name = "Redis";
  alias = "redis";
  inherit fields;

  helpers = {
    usesSentinel = dep: (dep.out.sentinel or null) != null;
    requirePlaintext = who: dep: ...;
  };
}
```

Today each file assembles its own result, so the files have drifted. Redis
passes on `assertions` and leaves out `require`, and Gateway does the
opposite. With one builder, every contract has the same validators, and a
helper cannot take the name of one.

A package calls a helper by the same path it is defined under, such as
`kix.contracts.redis.helpers.usesSentinel`. The longer path is accepted: it
shows at the call site which functions belong to one contract, and it
matches the `helpers` argument of `mkContract`.

`helpers` and `options` are part of the contract's promise. A stable
contract does not remove or change one in a patch release.

`kix.options.oidc` and `kix.options.mail` move to
`kix.contracts.oidc.options` and `kix.contracts.smtp.options`. The old names
are refused with an error that names the new ones.

### The Redis dependency is named `redis`

Readers take the Redis contract as the dependency `valkey` today, which
names one implementation. A reader that takes ElastiCache through it has no
Valkey. The dependency becomes `redis`:

- The contract's `alias` is `redis`, and the `valkey` package answers the
  alias `redis`.
- `harbor`, `immich`, and `n8n` take `redis`. A cluster that sets
  `deps.valkey` on one of them, or gives an instance `aliases = [ "valkey" ]`
  for them to find, is refused with an error that names `redis`.
- The `valkey` package keeps its name, and so does its own `valkeyPassword`
  dependency.

The other seven contracts already use a dependency name that matches the
contract: `database`, `otlp`, `oidcProvider`, `oidc`, `gateway`, `smtp`, and
`clickhouse`.

### What does not change

- `mkContract` and `credentialsField` stay in the library.
- A publisher still passes its `out` through `check`, and a reader still
  declares `assertions` on its dependency.
- Extra fields on a publisher's `out` stay allowed. A package may honour two
  contracts, or publish details that only its sibling packages read.
  Forbidding extras would turn every addition into a contract change, and
  the contract is the part that should change least.

## Breaking changes this causes

| Change | Kind | Who is affected |
|---|---|---|
| Contract files move | None | Nobody. Packages reach contracts through `kix.contracts` |
| The ClickHouse contract moves under `kix.contracts` | None for users | The three ClickHouse packages and the ClickHouse unit tests change their imports |
| Helpers move under `helpers` (`kix.contracts.redis.usesSentinel` becomes `kix.contracts.redis.helpers.usesSentinel`) | Shows an error | Package authors, including private packages |
| `kix.options.oidc` and `kix.options.mail` move | Shows an error | Package authors, including private packages |
| The Redis dependency is renamed from `valkey` to `redis` | Shows an error | Every cluster that wires it |

Today the only users are Lithus and one personal cluster, so these are cheap
now and get more expensive with each new user.

## What was built

- `kix/contracts/stable/` and `kix/contracts/experimental/` hold the eight contracts, and
  `kix/contracts/default.nix` builds `kix.contracts` from the folder
  listing.
- `mkContract` takes `helpers` and `options` and returns the nine parts in
  the table above. The loader sets `here`, so a contract file does not name
  its own path. A field without `required` is required.
- `credentialKeys` is gone. A contract's credential keys are
  `fields.credentials.keys`.
- `kix/contracts/moved.nix` refuses the old helper names, and
  `kix/lib/vocab/default.nix` refuses `kix.options.oidc` and
  `kix.options.mail`.
- A package that renames a dependency sets `deps.<arg>.renamedFrom`, and the
  error for a missing dependency then says what it was called before. The
  Redis contract provides the value as `helpers.renamedFrom`.
- The test `levels-contract-shape` checks that every contract file returns
  the nine parts and no others.

## Open questions

1. **Does a contract get a docs page?** The folder is easy to browse, and a
   generated page for each contract would list its fields and which
   packages publish and read it.
2. **Does a contract carry its level in a field as well as in its folder?**
   Proposal: no. The folder is the one source, as for packages.
3. **Narrowing what a reader receives** is deferred in doc 165. When it is
   built, `helpers` is the place for anything a reader needs beyond the
   fields.
