# 77: Secret Access Control via the Module System — Design Doc

**Status:** Draft
**Related:** `76_secrets_design.md` (value flow + consumption), `75_secrets_what_actually_matters.md` (strategic framing), `74_secrets.md` (full RFC)

---

## Context

Doc 76 specifies how secret **values** flow through kix: `mkSecret`/`mkSecretRef`, the `out` API, the hash-verified deploy-time hydration. It explicitly does **not** address the other half of the secret problem: **who can encrypt and decrypt what**, and how that access policy is governed in a multi-team repo.

Today, sops gets its recipient list from a hand-written `.sops.yaml` per directory:

```yaml
creation_rules:
  - path_regex: clusters/nw1/.*\.enc\..*
    age: age1qqq...,age1zzz...
```

This is YAML-only, regex-based, and not composable. There is no Nix-level source of truth for *which keys exist*, *which teams those keys belong to*, or *which secrets a given team is authorized to encrypt to*. A team that wants to add a new operator key has to hand-edit `.sops.yaml`, manually rekey existing files, and remember which paths are theirs.

This doc proposes a **module-system layer** on top of sops that:

1. Gives teams a Nix-native, composable way to declare keys, team memberships, and access rules from their own modules.
2. Generates `.sops.yaml` deterministically from the resolved module config.
3. Validates at build time that every secret referenced from a cluster (via `mkSecret { source = ... }`) is covered by an access rule, and that the file on disk is encrypted to the declared recipient set.
4. Provides a `kix secrets rekey` operation that re-encrypts every affected file when team membership changes — the operational win agenix offers, but without giving up sops's structured encryption or multi-backend support.

This layer sits **alongside** the value layer in 76. The hash model in 76 is unchanged: the hash is taken over decrypted plaintext, so rekeying does not invalidate any content hash. The two systems are orthogonal — one governs *content*, the other governs *recipients*.

---

## 1. The module schema

The new module set lives at the repo root in `kix/lib/modules/secrets.nix` and is evaluated via `lib.evalModules`. The top-level entrypoint is `secrets-config.nix` at the repo root, which imports per-team modules.

```nix
# kix/lib/modules/secrets.nix
{ lib, config, ... }:
let
  inherit (lib) mkOption types literalExpression;

  keyType = types.submodule ({ name, ... }: {
    options = {
      publicKey = mkOption {
        type = types.str;
        description = "age public key (age1...) or PGP fingerprint.";
      };
      kind = mkOption {
        type = types.enum [ "user" "machine" "ci" ];
        description = "What this key represents.";
      };
      owner = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Human owner (for users: their handle; for machines: responsible team).";
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
    };
  });

  teamType = types.submodule ({ name, config, ... }: {
    options = {
      members = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Key names directly in this team.";
      };
      inherits = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Other team names whose members are transitively included.";
      };
      ownedPaths = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Glob patterns this team is authorized to write rules for.
          Rules contributed by a module that target paths outside any
          team's ownedPaths fail at evaluation. Empty = no ownership claim
          (used for read-only "reference" teams like platform).
        '';
      };
      allMembers = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = "Transitively resolved members (this team + all inherited teams).";
      };
    };
  });

  ruleType = types.submodule {
    options = {
      pathGlob = mkOption {
        type = types.str;
        description = "Glob matching secret file paths relative to repo root.";
        example = literalExpression ''"clusters/nw1/**/*.enc.*"'';
      };
      recipients = mkOption {
        type = types.listOf types.str;
        description = "Key names or team names authorized to encrypt/decrypt matching files.";
      };
      contributedBy = mkOption {
        type = types.str;
        description = "Module identifier that added this rule (auto-set, used in error messages).";
      };
      priority = mkOption {
        type = types.int;
        default = 100;
        description = ''
          Lower priority wins on overlapping path globs (matches sops's
          first-match-wins by writing higher-priority rules first).
        '';
      };
    };
  };
in {
  options.kix.secrets = {
    keys = mkOption {
      type = types.attrsOf keyType;
      default = {};
      description = "Registered public keys (people, machines, CI).";
    };

    teams = mkOption {
      type = types.attrsOf teamType;
      default = {};
      description = "Named groups of keys; may transitively inherit other teams.";
    };

    rules = mkOption {
      type = types.listOf ruleType;
      default = [];
      description = "Path glob → authorized recipients mapping.";
    };

    # Computed (read-only)
    resolvedKeys = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      description = "Map of rule pathGlob → flat list of public keys (after team expansion).";
    };

    sopsConfig = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "The generated .sops.yaml structure.";
    };
  };

  config.kix.secrets = {
    # Resolve transitive team membership
    teams = lib.mapAttrs (teamName: team: {
      allMembers = resolveTransitiveMembers config.kix.secrets.teams teamName;
    }) config.kix.secrets.teams;

    # Resolve rules to flat key lists
    resolvedKeys = builtins.listToAttrs (map (rule: {
      name = rule.pathGlob;
      value = expandRecipients config.kix.secrets rule.recipients;
    }) config.kix.secrets.rules);

    # Generate .sops.yaml structure
    sopsConfig = {
      creation_rules = map (rule: {
        path_regex = globToRegex rule.pathGlob;
        age = lib.concatStringsSep "," (
          expandRecipients config.kix.secrets rule.recipients
        );
      }) (lib.sort (a: b: a.priority < b.priority) config.kix.secrets.rules);
    };
  };
}
```

The helper functions (`resolveTransitiveMembers`, `expandRecipients`, `globToRegex`) live in `kix/lib/secrets-access.nix`. They are pure Nix and tested in `tests/lib/secrets-access.nix`.

---

## 2. How teams contribute

Each team owns a module file. The top-level entrypoint imports them:

```nix
# secrets-config.nix at repo root
{
  imports = [
    ./teams/platform/secrets-module.nix
    ./teams/nw1-ops/secrets-module.nix
    ./teams/dev/secrets-module.nix
    ./clusters/test-secrets/secrets-module.nix
  ];
}
```

### Platform team — defines the base team and shared keys

```nix
# teams/platform/secrets-module.nix
{ ... }: {
  kix.secrets.keys = {
    luc = {
      publicKey = "age1qqqluc...";
      kind = "user";
      owner = "luc";
    };
    clo = {
      publicKey = "age1qqqclo...";
      kind = "user";
      owner = "clo";
    };
    ci-main = {
      publicKey = "age1qqqci...";
      kind = "ci";
      owner = "platform";
      description = "GitHub Actions deploy key for main branch builds.";
    };
  };

  kix.secrets.teams.platform = {
    members = [ "luc" "clo" "ci-main" ];
    # No ownedPaths — platform is a reference team that other teams inherit from.
  };
}
```

### nw1-ops team — extends platform, adds its own machine key, owns its cluster

```nix
# teams/nw1-ops/secrets-module.nix
{ ... }: {
  kix.secrets.keys.nw1-deployer = {
    publicKey = "age1qqqja1...";
    kind = "machine";
    owner = "nw1-ops";
    description = "nw1 cluster operator deploy identity.";
  };

  kix.secrets.teams.nw1-ops = {
    inherits = [ "platform" ];
    members = [ "nw1-deployer" ];
    ownedPaths = [ "clusters/nw1/**" "kix/packages/nw1-*/**" ];
  };

  kix.secrets.rules = [
    {
      pathGlob = "clusters/nw1/**/*.enc.*";
      recipients = [ "nw1-ops" ];
    }
    {
      pathGlob = "clusters/nw1/critical/**/*.enc.*";
      recipients = [ "nw1-ops" ];
      priority = 50;  # higher priority — matches before the broader rule
    }
  ];
}
```

### Cluster-local module — extends with cluster-specific keys

A cluster can contribute its own module without touching team files. Useful for one-off third-party integrations (e.g. a vendor that needs read access to a single shared secret):

```nix
# clusters/test-secrets/secrets-module.nix
{ ... }: {
  kix.secrets.keys.vendor-readonly = {
    publicKey = "age1qqqvendor...";
    kind = "user";
    owner = "external:acme";
    description = "Acme Corp read-only access for shared API key (revoke 2026-12-01).";
  };

  kix.secrets.rules = [{
    pathGlob = "clusters/test-secrets/shared-api.enc.json";
    recipients = [ "platform" "vendor-readonly" ];
    priority = 10;
  }];
}
```

The standard module-system rules apply: multiple modules contributing to `kix.secrets.keys` get merged via `mkMerge`. Conflicts (same key name with different `publicKey`) fail at evaluation.

---

## 3. Path-ownership enforcement

The `ownedPaths` mechanism prevents one team from grabbing access to another team's secrets. After resolution, the module system asserts:

> Every rule whose `pathGlob` falls under any team's `ownedPaths` must be contributed by a module that has the right to write rules for that path.

Concretely, "right to write" is determined by: the rule's `contributedBy` (the module file path) must live under one of the owning team's ownedPaths, OR the rule must be contributed by a designated "platform" module marked with `kix.secrets._trustedRuleSources = [ ... ]`.

This is a **build-time guard**, not a security boundary — anyone with commit access to `teams/nw1-ops/` can edit it. The point is to make accidental cross-team rule pollution impossible and to make deliberate cross-team grants visible in PR review (the change has to land in the owning team's directory).

```
error: secret rule contributed by clusters/dev/secrets-module.nix
  pathGlob "clusters/nw1/**/*.enc.*" falls under team "nw1-ops"
  (ownedPaths: clusters/nw1/**, kix/packages/nw1-*/**)
  but no module under those paths contributed this rule.

  fix: move this rule into teams/nw1-ops/secrets-module.nix,
       or have nw1-ops add an explicit grant rule there.
```

---

## 4. Generation: `.sops.yaml` as a build output

`.sops.yaml` files are **generated**, not hand-edited. The module evaluation produces a derivation:

```nix
# flake.nix
packages.secrets-config = pkgs.runCommand "sops-config" {} ''
  mkdir -p $out
  echo '${builtins.toJSON evaluatedSecrets.config.kix.secrets.sopsConfig}' \
    | ${pkgs.yq-go}/bin/yq -P . > $out/.sops.yaml
'';
```

```bash
$ nix build .#secrets-config
$ cp result/.sops.yaml .sops.yaml  # commit the generated file
```

A pre-commit hook (and a CI check) verifies that the committed `.sops.yaml` matches `nix build .#secrets-config`. Drift between the Nix source of truth and the on-disk file fails CI:

```
error: .sops.yaml is out of sync with secrets-config.nix
  run: nix build .#secrets-config && cp result/.sops.yaml .sops.yaml
```

We commit the generated file (rather than reading it dynamically) because sops needs `.sops.yaml` at encryption time, before any Nix tooling has run. The committed file is the build cache.

---

## 5. Build-time validation against cluster references

The killer feature of doing this in Nix instead of YAML: we can cross-reference the **declared rules** against the **actual `mkSecret { source = ... }` calls** in a cluster build.

During cluster evaluation, every `scope.mkSecret` call registers its `source` path in a side-channel (the existing `attachCtx` context already tracks this for the Merkle DAG). After the cluster is built, kix walks the registered sources and checks:

1. **Every source is covered by a rule.** A `mkSecret { source = ./secrets/foo.enc.json; }` with no matching `pathGlob` fails the build with:
   ```
   error: secret source not covered by any access rule
     source: clusters/orphan/secrets/foo.enc.json
     declared in: kix/packages/orphan-app/default.nix:42

     no rule in secrets-config matches this path. Add a rule to the
     owning team's secrets-module.nix:
       { pathGlob = "clusters/orphan/**/*.enc.*"; recipients = [ "your-team" ]; }
   ```

2. **The file on disk is encrypted to the declared recipient set.** kix reads the sops metadata of the actual file (the `sops.age[].recipient` list) and compares it to the resolved recipient list for the matching rule. Mismatch → build error:
   ```
   error: secret file recipients do not match the declared rule
     source:    clusters/nw1/secrets/db.enc.json
     rule:      "clusters/nw1/**/*.enc.*" → nw1-ops
     expected:  age1qqqluc..., age1qqqclo..., age1qqqci..., age1qqqja1...
     actual:    age1qqqluc..., age1qqqclo...   (missing: ci-main, nw1-deployer)

     fix: kix secrets rekey clusters/nw1/secrets/db.enc.json
   ```

This catches the most common operational failure mode: a key gets added to a team, but old secret files are never rekeyed, so the new operator can't decrypt them at deploy time. Today this fails at `kix deploy` with an opaque sops error. With this design it fails at `nix build` with a precise message and a fix command.

The validation runs inside the Rust `cli/kix` evaluator (it has filesystem access; the Nix evaluator does not). It uses the `kix.dev/sops-source` annotations injected by `mkSecret` (already implemented in 76) to find the files, and a small sops metadata reader to extract the recipient list without decrypting.

---

## 6. Rekeying

```bash
# Rekey one file
$ kix secrets rekey clusters/nw1/secrets/db.enc.json

# Rekey everything that drifted from its declared rule
$ kix secrets rekey --all
Found 3 files needing rekey:
  clusters/nw1/secrets/db.enc.json          (missing: ci-main, nw1-deployer)
  clusters/nw1/secrets/api.enc.json         (missing: nw1-deployer)
  clusters/test-secrets/shared-api.enc.json (missing: vendor-readonly)
Rekey all? [y/N]: y
  ✓ clusters/nw1/secrets/db.enc.json
  ✓ clusters/nw1/secrets/api.enc.json
  ✓ clusters/test-secrets/shared-api.enc.json
```

`kix secrets rekey` is a thin wrapper around `sops updatekeys`, but driven by the resolved module config rather than ad-hoc CLI flags. It is **not** a primitive — it just calls sops with the recipient list the module system computed. This means it inherits sops's correctness guarantees and works with any sops backend (age, KMS, etc.).

Rekeying does not change the decrypted plaintext, so the **content hashes from doc 76 are unaffected**. No rebuild needed for value-side dependents.

---

## 7. Deploy & diff integration

**Premise:** changing access control is a change that needs review and approval, exactly like changing a manifest. The recipient set on a secret is **state**, and any change to that state must flow through `kix diff` and `kix deploy` as a first-class entity — surfaced to reviewers, gated on approval, and enforced before manifests are applied. This is the operational surface that turns the module schema in §1 from a config-as-code exercise into a governance tool.

This section is the main reason this layer exists in kix at all rather than as a standalone Nix library: kix already owns the diff/deploy pipeline, so access governance can ride on the same review path as the rest of the cluster state.

### 7.1 Access state in the diff output

`kix diff` already shows manifest deltas between two cluster builds (doc 28). It is extended to also evaluate the secrets module set on both sides of the comparison and emit access deltas alongside the manifest deltas:

```bash
$ kix diff main HEAD --cluster nw1

== MANIFEST CHANGES ==
~ apps/web/Deployment/web (image: v1.2.0 → v1.3.0)

== ACCESS CHANGES ==
+ key added: nw1-deployer-2 (machine, owner: nw1-ops)
    age1qqqja1deployer2...
~ team nw1-ops:
    members: [nw1-deployer]  →  [nw1-deployer, nw1-deployer-2]
    allMembers (resolved): +nw1-deployer-2

== EFFECTIVE ACCESS DELTA ==
+ nw1-deployer-2 gains read access to:
    clusters/nw1/secrets/db.enc.json
    clusters/nw1/secrets/api-keys.enc.json
    clusters/nw1/critical/root-ca.enc.json
  (3 files, 1 marked critical)

== REKEY REQUIRED ==
3 files must be rekeyed before deploy:
    clusters/nw1/secrets/db.enc.json
    clusters/nw1/secrets/api-keys.enc.json
    clusters/nw1/critical/root-ca.enc.json
  run: kix secrets rekey --all
```

The diff has three sections that matter for governance:

1. **Module-level changes** — raw additions/removals/edits to keys, teams, rules. The "what changed in the source".
2. **Effective access delta** — the resolved view: which key gained or lost access to which file. This is what a reviewer actually evaluates. Computed by diffing the resolved recipient set per file between the two builds.
3. **Rekey required** — files where the on-disk recipient set will diverge from the new declared rule set. Deploy will refuse to proceed until these are rekeyed.

The effective delta is the headline because reviewers don't think in terms of "team membership transitively expanded": they think in terms of "did this PR give Eve access to the production database password". The delta makes that question answerable in one glance.

### 7.2 Severity tiers

Access deltas are classified by severity, displayed in the diff and used for approval gating:

| Tier | What | Examples |
|---|---|---|
| **info** | Pure additions of new isolated state | New secret added with rule covering it; new key registered but not added to any team |
| **low** | Recipient set grows on non-critical secrets | Adding a CI key to a team that already has access to similar files |
| **medium** | Recipient set grows on any secret OR new team grants access to existing files | New developer added to nw1-ops; new rule covers existing files with broader recipient set |
| **high** | Recipient set shrinks (lockout risk) OR key revocation OR rule changes affecting `meta.classification = "critical"` secrets | Removing an operator key; revoking team membership; touching any secret marked critical |

Severity is computed by `kix diff` and printed at the top of each access change line (`[medium]`, `[high]`). It is derived from:
- the direction of change (grow vs. shrink),
- the `meta.classification` field on the affected `mkSecret` instances (already in 76),
- whether the change touches a key marked `kind = "machine"` or `"ci"` (typically lower severity than user keys, which represent humans being added/removed from sensitive scopes).

### 7.3 Approval gates

`kix deploy` refuses to apply a build whose effective access delta from the previously-deployed build contains anything above `info` unless approval is provided. Approval has two forms:

```bash
# Interactive: deploy walks the operator through each access change
$ kix deploy nw1
nw1: 1 manifest change, 3 access changes (1 high, 2 medium)

[high] nw1-deployer-2 gains read access to clusters/nw1/critical/root-ca.enc.json
       (root-ca is marked classification=critical)
       Approve? [y/N/details]: details

       Source change: teams/nw1-ops/secrets-module.nix
         + members += "nw1-deployer-2"
       Resolved by rule: clusters/nw1/critical/**/*.enc.* → nw1-ops
       Contributed by:  teams/nw1-ops/secrets-module.nix:18
       Last modified:   commit a1b2c3d by clo (2026-04-06)

       Approve? [y/N]: y
[medium] nw1-deployer-2 gains read access to clusters/nw1/secrets/db.enc.json — Approve? [y/N]: y
[medium] nw1-deployer-2 gains read access to clusters/nw1/secrets/api-keys.enc.json — Approve? [y/N]: y

3 access changes approved. Proceeding with rekey + deploy...
```

```bash
# Non-interactive (CI): approval token committed to the PR
$ kix deploy nw1 --approve-access-token=$(cat .kix/access-approval.json)
```

The approval token is a signed JSON document produced by `kix secrets approve <build-hash>` that lists every access delta and the human who approved each. It pins to the build hash, so any subsequent change to the secrets module invalidates the token and forces re-approval. CI workflows commit the token to the PR as part of the merge requirement; merging to main without it fails the deploy job.

This is the "review-by-construction" property: there is no path to apply an access change without an explicit human acknowledgement that's traceable to a specific build hash.

### 7.4 Deploy-time enforcement

Before any K8s manifests are applied, `kix deploy` runs a **secrets gate**:

1. **Resolve** the secrets module set for the current build.
2. **Walk** every `mkSecret { source = ... }` referenced by the cluster.
3. **Verify** the on-disk recipient list of each source file equals the resolved rule's recipient list.
4. **If any file is stale**: refuse to deploy. Print the rekey command. Do not apply manifests.
5. **If any registered key was removed since the last deployed build but files still encrypt to it**: refuse to deploy. This is the revocation safety check. Print the affected files and require `kix secrets rekey --all` before retry.

Step 5 is important because it closes the most dangerous gap: a removed key whose old ciphertext is still in git is still readable by whoever holds that key. The deploy gate ensures the rotation actually completed before the cluster moves forward in any way. Until the rekey lands in a commit, no deploy proceeds — including unrelated manifest changes. This forces the revocation to be the immediately-next operation, not "we'll get to it".

### 7.5 Rekey as a deploy phase

For convenience in interactive use, `kix deploy --rekey` will perform the rekey itself (after access approval) and continue the deploy. In CI, this is **off by default**: rekeying is a separate commit that goes through review like any other change. A bot may run `kix secrets rekey --all` and open a follow-up PR, but the merge of that PR is what unblocks the deploy.

```bash
$ kix deploy nw1 --rekey
nw1: 3 access changes (1 high, 2 medium) — approve as above
3 files need rekey. Rekey now? [y/N]: y
  ✓ clusters/nw1/secrets/db.enc.json
  ✓ clusters/nw1/secrets/api-keys.enc.json
  ✓ clusters/nw1/critical/root-ca.enc.json
Proceeding with deploy...
```

### 7.6 Drift detection

Independent of any deploy, `kix diff --secrets-only` (and the periodic operator drift check from doc 28) compares the on-disk sops files against the resolved module config and reports drift. This catches:
- Files manually re-encrypted out-of-band (someone ran `sops` directly).
- Modules edited without running `kix secrets rekey`.
- Keys that exist in `.sops.yaml` but no longer in the module set, or vice versa.

The operator emits a `SecretAccessDrift` reconciliation event when drift is detected, which surfaces through the same observability path as manifest drift.

### 7.7 What this gives us that pure `.sops.yaml` cannot

| Concern | Hand-written `.sops.yaml` | This design |
|---|---|---|
| Surface access change in diff | No — YAML diff only, no resolved view | Yes — effective per-file delta |
| Block deploy on stale recipients | No — fails opaquely at sops decrypt time | Yes — explicit gate with fix command |
| Block deploy on incomplete revocation | No | Yes — deploy halts until rekey lands |
| Require human approval for grants | Only via PR review on YAML | Build-hash-pinned approval token, traceable per delta |
| Severity classification | None | Tiered, classification-aware |
| Audit trail per access change | git blame on `.sops.yaml` | Module-level + resolved-delta + signed approval per build |

---

## 8. Where the module set is evaluated

The new module set is evaluated independently of the cluster module set. It does **not** participate in the cluster fixpoint — there's no reason for a cluster's package wiring to see the recipient list, and keeping them separate avoids polluting the cluster eval graph with secret governance state.

```nix
# kix/lib/secrets-eval.nix
{ lib, modules ? [] }:
(lib.evalModules {
  modules = [
    ./modules/secrets.nix
    ../../secrets-config.nix  # repo-root entrypoint
  ] ++ modules;
}).config.kix.secrets
```

The cluster-build pipeline calls this evaluator to obtain the resolved rules and passes them to the validation step. The CLI calls it for `kix secrets rekey` and `kix secrets list-keys`.

---

## 9. CLI surface

Adds the following commands to the existing `kix secrets` namespace from doc 76. Note that the diff and approval surface lives on `kix diff` / `kix deploy` (§7), not as standalone secret commands — governance is part of the main pipeline, not a sidecar.

```bash
# Show resolved access matrix (which keys can read which paths)
$ kix secrets access-rules
PATH GLOB                              RECIPIENTS                                CONTRIBUTED BY
clusters/nw1/critical/**/*.enc.*       luc, clo, ci-main, nw1-deployer          teams/nw1-ops/secrets-module.nix
clusters/nw1/**/*.enc.*                luc, clo, ci-main, nw1-deployer          teams/nw1-ops/secrets-module.nix
clusters/test-secrets/shared-api...    luc, clo, ci-main, vendor-readonly       clusters/test-secrets/secrets-module.nix

# List all known keys
$ kix secrets list-keys
NAME            KIND     OWNER       DESCRIPTION
luc             user     luc
clo             user     clo
ci-main         ci       platform    GitHub Actions deploy key for main branch builds.
nw1-deployer    machine  nw1-ops     nw1 cluster operator deploy identity.
vendor-readonly user     external:acme  Acme Corp read-only access (revoke 2026-12-01).

# Rekey files that have drifted from their declared rule
$ kix secrets rekey [--all | <path>...]
```

Plus governance subcommands tied to the deploy pipeline:

```bash
# Produce a signed approval token for an access delta (CI workflows)
$ kix secrets approve <build-hash>
  → writes .kix/access-approval.json bound to that build hash

# Show drift between on-disk sops files and resolved module config
$ kix diff --secrets-only

# Revoke a key (removes from module + initiates rekey of all affected files)
$ kix secrets revoke <keyName>
```

The existing `kix secrets list` (from 76) already shows secrets-as-objects. The new commands show the **access governance** view, which is the complement.

---

## 10. Migration

Today the repo has hand-written `.sops.yaml` files (e.g. `clusters/test-secrets/.sops.yaml`). Migration is mechanical:

1. **Bootstrap a `secrets-config.nix`** at repo root with one team containing every existing recipient key.
2. **Generate rules** from the existing `.sops.yaml` files via `kix secrets import-yaml clusters/*/.sops.yaml`. This produces a draft module file.
3. **Refactor by hand** into per-team modules as the repo grows multi-team. There's no rush — a single-team `secrets-config.nix` is the same level of complexity as a single `.sops.yaml`, just in Nix.
4. **Add CI check** that `.sops.yaml` is in sync with `nix build .#secrets-config`.
5. **Delete the source-of-truth status** from the YAML files. They become build artifacts.

No changes are required to existing `mkSecret` calls — the value layer (76) is untouched.

---

## 11. Alternatives considered

### A. Stay with hand-written `.sops.yaml`

Today's status quo. Works for one team, breaks down at multi-team scale: no composition, no validation, no transitive team membership, no audit trail of who added what. Ruled out by the multi-team requirement.

### B. Switch to agenix

Discussed in chat preceding this doc. Loses sops's structured encryption, multi-backend support, and the existing 76 implementation. The "Nix-native" win is real but doesn't justify rebuilding the value layer. Ruled out.

### C. Use sops-nix

sops-nix is a NixOS module — its value is activation-time decryption into `/run/secrets/`, which doesn't apply to a K8s deploy model. It does **not** provide a Nix API for `.sops.yaml` recipient management; that's still hand-written YAML in sops-nix workflows. Ruled out.

### D. Plain Nix `let`-bindings in a single `secrets.nix`

The first-pass design from chat. Works for a small team but doesn't compose across modules: every team would have to edit the same file. Ruled out by the multi-team requirement.

### E. Module system, but `kix.secrets` lives inside the cluster module set

Considered but rejected. Pollutes cluster eval with state that's irrelevant to package wiring, and forces per-cluster duplication of team definitions. The independent module set in §8 keeps governance and wiring orthogonal.

### F. Module system without deploy/diff integration

A pure config-as-code layer that just generates `.sops.yaml` and validates references at build time, with no `kix diff`/`kix deploy` integration. Simpler to ship, but loses the central operational benefit: access changes would still flow through git review on YAML output, with no resolved-delta view, no approval gate, no revocation safety. Ruled out — the deploy/diff integration is the reason this lives in kix at all instead of as a standalone Nix library.

---

## 12. Migration / compatibility

- **`mkSecret` and `mkSecretRef` are unchanged.** This layer adds a sibling concern, not a replacement.
- **Hash model from 76 is unchanged.** Rekeying does not invalidate content hashes (plaintext is unchanged).
- **Existing `.sops.yaml` files** become build outputs. The CI sync check is the breaking change — repos must run `nix build .#secrets-config` after any module change.
- **`kix deploy` gains a new gate** (§7.4). Existing deploys to clusters without secrets are unaffected; clusters with secrets get the access-state check between build and apply. First deploy after this lands requires baselining the access state.
- **No DSL changes** for package authors. Only operators who manage access policy interact with the new module set.

---

## 13. Open questions

### 13.1 Where is the trust root for `_trustedRuleSources`?

Path-ownership enforcement (§3) needs a way to designate a "platform" module that can write rules anywhere — for cross-team grants and bootstrap. Options:

- **Hardcoded path**: `teams/platform/secrets-module.nix` is always trusted.
- **Marker option**: any module can set `kix.secrets._trustedRuleSources = [ ./this-module.nix ]`, but the marker itself can only be set by an already-trusted module (chicken-and-egg fixed by hardcoding the bootstrap entry).
- **CODEOWNERS-style**: a separate `.kix/trusted-secret-modules` file outside the module system, hand-curated and PR-reviewed.

**Mitigated by §7.3 approval gates**: even if path ownership is loose, any cross-team grant surfaces in the effective access delta and requires approval pinned to the build hash. Path ownership becomes a *first line of defence* (catch accidents at build time) rather than the *only line* (which would have demanded watertight bootstrap semantics). Still leaning toward the marker option with a hardcoded bootstrap entry for `teams/platform/`, but the design no longer depends on getting this perfect.

### 13.2 How granular should glob matching be?

`**/*.enc.*` covers most cases, but some teams may want per-environment recipient sets (`production/**` more restrictive than `staging/**`). The priority field in §1 handles this: write the production rule with lower priority (= higher precedence) than the broader rule. Need to verify sops's `path_regex` semantics match this expectation — specifically, that the first matching rule wins and we don't get unexpected recipient unions.

### 13.3 Validation cost on large repos

Reading sops metadata from every secret file on every `nix build` could add latency. Mitigations: cache by file mtime + content hash, only validate files referenced by the cluster being built (not the whole repo), make validation a separate `kix secrets check` command that's invoked by CI rather than every local build. The deploy gate in §7.4 also reduces the pressure on build-time validation — even if we relax it locally, the deploy path catches drift before anything reaches a cluster. Probably start with "only validate files referenced by the current build" plus the deploy gate as the safety net.

### 13.4 ~~Key revocation workflow~~ (resolved by §7.4)

Resolved: §7.4 specifies that `kix deploy` halts on any registered key removed since the last deployed build whose old ciphertext is still in git. Until `kix secrets revoke` + rekey land in a commit, no deploy proceeds — including unrelated manifest changes. This is the strict-revocation behaviour we want, encoded in the deploy gate rather than as a separate workflow.

### 13.5 Integration with cluster-level access boundaries

Doc 76's open question 10.5 (external hash overrides) and this doc's recipient management both want cluster-level governance hooks. With §7 in place, both flow through the same `kix diff`/`kix deploy` surface anyway — the question of "shared module namespace or separate" is now mostly cosmetic. Proposal: keep the option trees separate (`kix.secrets.access.*` for this doc, `kix.secrets.values.*` for hash overrides per 76), but route both through the same diff/approval pipeline so reviewers see one unified governance section. Worth a small follow-up doc once 76's open question 10.5 firms up.

### 13.6 Severity tier configurability

§7.2 hardcodes the severity matrix. Some orgs may want to tighten it (e.g. classify *all* additions as medium, not info) or tag specific paths/teams with custom severity multipliers. Could expose this as `kix.secrets.severity.{rules,classifications,defaultTier}` in the module set. Not blocking for v1 — ship the hardcoded matrix and add configurability when someone asks.

### 13.7 Approval token format and trust model

§7.3 sketches an approval token bound to a build hash but doesn't pin down the signing scheme. Options: (a) GPG-signed JSON with the approver's git-known key, (b) ssh-keygen signatures using the operator's SSH key, (c) sigstore/cosign keyless signing. Sigstore is the most operationally friendly (no key distribution) but adds a dependency. SSH signing is the cheapest. Needs a small follow-up decision before §7.3 can be implemented.

### 13.8 What happens on KMS / multi-backend setups?

The schema currently models recipients as a flat list of "key names" that resolve to age public keys. sops also supports KMS ARNs, GCP KMS resource IDs, PGP fingerprints, etc. The `keyType` submodule should grow a `backend` field (`age | aws-kms | gcp-kms | pgp | vault`) and the generator should emit the correct sops creation_rule field per backend. Not blocking — start with age-only and extend.
