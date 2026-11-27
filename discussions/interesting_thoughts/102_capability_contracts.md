# 102 — Capability Contracts

## Status

Deferred (2026-04-15). Split off from `100_package_dsl_ergonomics_survey.md`
item D1. Not pursued because tight coupling in wiring is currently a
feature, not a bug: only actively-wired paths need to work together, and
an eval-time error on shape drift is acceptable. Revisit when a concrete
provider-swap driver appears.

## Problem (restated)

Every consumer package learns each provider's exact `.out` shape by
inspection:

```nix
# immich
env = [
  (kix.env.fromValue "DB_HOST" self.database.out.host)
  (kix.env.fromValue "DB_PORT" (toString self.database.out.port))
  (kix.env.fromSecret "DB_PASSWORD" self.database.out.credentials.ref "password")
  (kix.env.fromValue "REDIS_URL" "redis://${self.valkey.out.fqdn}:6379")
];
```

If stackgres-operator renames `out.host` → `out.primaryHost`, the break
is silent until an eval at the consumer call site, with no message that
points back at the provider side.

Doc 97 (`service_contract_primitives`) standardizes *that* a contract
exists (`mkServiceRef`, `scope.provideService`). It does not standardize
*what shape* that contract has for a given capability (postgres, redis,
s3).

## Sketch (not pursued)

```nix
# provider
meta.provides = [ { contract = kix.contracts.postgres; version = "15"; } ];

# consumer
deps.database.contract = kix.contracts.postgres;
env = kix.env.fromContract self.database;  # emits DB_HOST/PORT/USER/PASSWORD
```

`contracts/postgres.nix`, `contracts/redis.nix`, `contracts/s3.nix` would
each be a module schema (reuse NixOS `lib.types`) describing the required
`out.*` surface. Resolver in `eval/resolve.nix` rejects mismatches at
phase-1 pre-pass.

## Why deferred

1. **Tight coupling is the current contract.** A consumer wires to a
   specific provider; shape matching happens at eval. This is simple,
   traceable, and already catches breakage. The pain point (silent
   rename) is mitigated by the fact that renames show up in the very
   next CI build of any consumer.
2. **No pull from real drivers yet.** Multi-provider swap (postgres ↔
   CNPG, for instance) is the scenario where contracts earn their
   weight. Until at least one package is under active pressure to
   abstract its provider, a contract layer is speculative.
3. **NixOS precedent.** NixOS modules do not use a nominal contract
   system for service interop; they use option types and structural
   matching. kix/lib mirrors that today. Introducing contracts would be
   a new concept to learn, paid for by hypothetical future flexibility.
4. **Hard design questions unanswered:** versioning, partial conformance
   (provider exposes 80% of expected surface), nominal vs structural,
   migration path for existing packages. None are worth resolving
   without a concrete driver.

## Revisit trigger

Open this back up when one of:

- A real provider-swap driver lands — e.g. doc 90's ludo horizon
  forcing postgres ↔ CNPG on the same consumer set.
- We ship > 3 providers for the same capability (today: usually 1) and
  see shape drift between them in practice.
- A consumer breaks silently in production because of a provider `out`
  rename and we want a mechanism stronger than "eval catches it".

## First step if we do pursue it

A 50-line prototype against postgres only: define
`contracts/postgres.nix` as a plain module schema, wire stackgres-operator
as a provider and immich as a consumer, measure whether the eval error
on shape mismatch is materially better than the status quo. Decision on
module-typed vs structural would follow from that prototype, not
precede it.
