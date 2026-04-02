# 64 — MVP Implementation Approach

**Status:** Draft [undiscussed]
**Related:** `58_satchel_mvp_technical_requirements.md` (requirements), `46_thin_operator_production_plan.md` (operator design), `61_compliance_exports.md` (SARIF exports), `28_gitops_deploy.md` (deploy feature parity), `60_scorecard_rules_design.md` (scorecard)

---

## Purpose

Doc 58 maps Sam's needs to kix gaps. This document is the companion: **how** each gap gets closed, what the implementation looks like concretely, and where we can be clever about sequencing to get maximum value from minimum work.

The core insight: most of what Sam needs *already exists* in pieces. The MVP is less about building new capabilities and more about **surfacing, packaging, and connecting** what's already there.

---

## 1. `kix export` — The Exit Strategy Command

### Why first

Sam flagged lock-in as a concern. The exit story is kix's strongest selling point ("it's just YAML"), but it's invisible today. Shipping `kix export` makes it tangible and costs almost nothing.

### What exists

- `kix build <cluster>` already renders all manifests to stdout as YAML or JSON
- The manifests in the store are organized by store path (content-hash), not by human-readable structure

### Implementation

A new CLI command that reads the same store graph as `kix build` but writes files to disk in a directory structure:

```
output/
├── kube-system/
│   ├── Deployment-coredns.yaml
│   ├── Service-coredns.yaml
│   └── ConfigMap-coredns-corefile.yaml
├── immich/
│   ├── Deployment-immich-server.yaml
│   ├── Service-immich-server.yaml
│   ├── Ingress-immich.yaml
│   └── StatefulSet-postgres.yaml
└── cert-manager/
    ├── Deployment-cert-manager.yaml
    └── ...
```

**Concrete approach:**

```rust
// cli/kix-cli/src/commands/export.rs

pub fn run(args: &ExportArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster_output = ctx.eval_cluster_or_suggest(&args.cluster)?;

    for manifest in &cluster_output.raw_manifests {
        let namespace = manifest["metadata"]["namespace"]
            .as_str()
            .unwrap_or("cluster-scoped");
        let kind = manifest["kind"].as_str().unwrap_or("Unknown");
        let name = manifest["metadata"]["name"].as_str().unwrap_or("unnamed");

        let dir = args.output.join(namespace);
        std::fs::create_dir_all(&dir)?;

        let filename = format!("{}-{}.yaml", kind, name);
        let yaml = serde_yaml::to_string(manifest)?;
        std::fs::write(dir.join(&filename), yaml)?;
    }

    println!("Exported {} resources to {}",
        cluster_output.raw_manifests.len(),
        args.output.display());
    Ok(())
}
```

**Additions needed:**
- `ExportArgs` struct in `cli.rs` (cluster name, output dir, optional format flag)
- Register the subcommand
- Strip kix-internal annotations (`kix.dev/*`) from exported manifests — the output should be vanilla K8s YAML that `kubectl apply -f` accepts without any kix tooling

**Stretch:** `--kustomize` flag that also generates a `kustomization.yaml` per namespace, so the export is directly usable with kustomize/flux/argo.

**Effort estimate:** Small. Most of the logic already exists in `build.rs`. This is file I/O + annotation stripping.

---

## 2. CI Integration — Diff as PR Comment

### Why this matters

The `terraform plan` → review → `terraform apply` loop is what Sam (and most teams) already do. kix's diff engine is more powerful than `terraform plan` (it shows package-level grouping, resource-level diffs, blast radius), but none of this is wired into CI.

### What exists

- `kix diff` outputs structured JSON with exit code 2 on differences
- `kix diff` text mode produces colored, human-readable output
- `kix deploy` handles the apply side
- `kix snapshot save` can capture cluster state for offline diffing

### Implementation: GitHub Action

The action itself is thin — the heavy lifting is done by `kix diff` and `kix deploy`. What we're building is a wrapper that:

1. Installs Nix (with binary cache)
2. Builds the cluster
3. Runs diff or deploy
4. Posts results

```yaml
# .github/actions/kix/action.yml
name: 'kix CI'
description: 'Build, diff, and deploy kix clusters'
inputs:
  cluster:
    description: 'Cluster name to evaluate'
    required: true
  mode:
    description: '"diff" (PR) or "deploy" (merge)'
    required: true
    default: 'diff'
  kubeconfig:
    description: 'Base64-encoded kubeconfig for cluster access'
    required: false
  nix-cache:
    description: 'Nix binary cache URL (cachix, attic, etc)'
    required: false

runs:
  using: 'composite'
  steps:
    - uses: DeterminateSystems/nix-installer-action@main
    - uses: DeterminateSystems/magic-nix-cache-action@main

    - name: Build cluster
      shell: bash
      run: nix build .#cluster-${{ inputs.cluster }} --extra-experimental-features pipe-operators

    - name: Diff (PR mode)
      if: inputs.mode == 'diff'
      shell: bash
      run: |
        # Run diff, capture output and exit code
        set +e
        DIFF_TEXT=$(kix diff ${{ inputs.cluster }} 2>&1)
        DIFF_EXIT=$?
        DIFF_JSON=$(kix diff ${{ inputs.cluster }} -o json 2>/dev/null)
        set -e

        # Build PR comment
        if [ $DIFF_EXIT -eq 0 ]; then
          COMMENT="### ✅ kix diff: No changes\nCluster \`${{ inputs.cluster }}\` is in sync."
        else
          # Parse JSON for summary stats
          ADDED=$(echo "$DIFF_JSON" | jq '.packages.added | length')
          REMOVED=$(echo "$DIFF_JSON" | jq '.packages.removed | length')
          CHANGED=$(echo "$DIFF_JSON" | jq '.packages.changed | length')
          UNCHANGED=$(echo "$DIFF_JSON" | jq '.packages.unchanged')

          COMMENT=$(cat <<EOFCOMMENT
        ### 📦 kix diff: Changes detected

        | | Count |
        |---|---|
        | Packages added | $ADDED |
        | Packages removed | $REMOVED |
        | Packages changed | $CHANGED |
        | Packages unchanged | $UNCHANGED |

        <details>
        <summary>Full diff</summary>

        \`\`\`
        $DIFF_TEXT
        \`\`\`

        </details>
        EOFCOMMENT
          )
        fi

        # Post as PR comment (requires GITHUB_TOKEN)
        gh pr comment ${{ github.event.pull_request.number }} \
          --body "$COMMENT" \
          --edit-last || \
        gh pr comment ${{ github.event.pull_request.number }} \
          --body "$COMMENT"

    - name: Deploy (merge mode)
      if: inputs.mode == 'deploy'
      shell: bash
      run: kix deploy ${{ inputs.cluster }} --yes
```

**User's workflow file would look like:**

```yaml
# .github/workflows/kix.yml
name: kix
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  kix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: kix diff (PR)
        if: github.event_name == 'pull_request'
        uses: ./.github/actions/kix
        with:
          cluster: dev
          mode: diff

      - name: kix deploy (merge)
        if: github.event_name == 'push'
        uses: ./.github/actions/kix
        with:
          cluster: dev
          mode: deploy
          kubeconfig: ${{ secrets.KUBECONFIG }}
```

### Key decisions

**Snapshot-based diff vs live-cluster diff:** For CI, we want snapshot-based diffing (compare the new build against a saved snapshot of the previous deployment). This avoids needing cluster credentials in the PR job. The flow:

1. After each deploy, `kix snapshot save` captures the deployed state and stores it as a CI artifact
2. On PR, diff compares the new build against the saved snapshot — no cluster access needed
3. On merge, deploy uses real cluster credentials

This is cleaner than live-cluster diff in CI because:
- PR authors don't need cluster credentials
- Diff is deterministic (not affected by manual drift between PR open and merge)
- Faster (no API server round-trips)

**Alternative:** If snapshot management is too complex for MVP, just require cluster credentials for diff too. Less elegant, works fine.

**SARIF integration (low-hanging fruit):** If `kix check` outputs SARIF (doc 61), GitHub Code Scanning picks it up natively. The scorecard rules already produce structured findings — SARIF export is a serialization exercise. This gives us code-review-integrated policy violations for free:

```yaml
    - name: Policy check
      run: kix check ${{ inputs.cluster }} --format sarif > results.sarif

    - uses: github/codeql-action/upload-sarif@v3
      with:
        sarif_file: results.sarif
```

**Effort:** Medium. The diff engine and deploy pipeline exist. The work is: (a) the composite action wrapper, (b) snapshot save-as-artifact flow, (c) PR comment formatting. SARIF export is a separate but synergistic effort.

---

## 3. `kix init` — First-Time Scaffolding

### Why it matters

Today, bootstrapping a new kix cluster requires: (a) knowing what a `flake.nix` should look like, (b) knowing which packages exist, (c) knowing how to write a cluster definition, (d) knowing which flavor to import. That's four things a new user must learn before seeing any output. `kix init` collapses this to zero.

### Implementation

Interactive scaffold that produces a working cluster definition:

```
$ kix init
? Provider: [gke / eks / aks / hetzner / kind / bare-metal]
> gke

? Cluster name: satchel-dev

? Include common packages?
  [x] ingress-nginx
  [x] cert-manager
  [ ] monitoring (kube-prometheus-stack)
  [ ] logging (loki)
  [x] external-secrets

? Domain (for ingress): dev.satchel.example

Creating:
  flake.nix
  clusters/satchel-dev.nix
  .github/workflows/kix.yml  (optional)
```

**Output structure:**

```nix
# clusters/satchel-dev.nix (generated)
{ pkgs, ... }:
{
  imports = [
    pkgs.lib.flavors.gke       # GKE capability defaults
  ];

  cluster.name = "satchel-dev";
  cluster.domain = "dev.satchel.example";

  # Deploy safety: only allow deploying to this context
  cluster.deploy.allowedContexts = [ "gke_project_zone_satchel-dev" ];

  services = {
    ingress-nginx = {};
    cert-manager = {};
    external-secrets = {};
  };
}
```

**Implementation approach:** This doesn't need to be in Rust initially. A `kix init` subcommand that shells out to a Nix expression or even a simple bash/nix script that generates the files. The value is in the curated templates, not the scaffolding engine.

**Concrete plan:**
1. Create `templates/` directory with provider-specific cluster definitions
2. `kix init` reads provider choice, fills in names/domains, writes files
3. Generated `flake.nix` includes kixpkgs as a flake input with correct boilerplate
4. Optional: generate a CI workflow file too

**What makes this good vs generic scaffolding:** The generated cluster definition should *build and diff* immediately. `nix build .#cluster-satchel-dev` should succeed out of the box, producing a valid set of manifests. This means the templates must use real packages that actually work together.

**Effort:** Medium. The templates need care (each provider combo must produce a working build). The command itself is trivial.

---

## 4. Terraform → kix Import Bridge

### The problem

Sam manages cloud resources with Terraform (Cloud SQL, GCS, Firebase, IAM). kix manages K8s resources. The bridge between them is: how do Terraform outputs become kix DI inputs?

### What exists

`mkImport` already handles this conceptually — it creates lightweight instances with `out` properties that participate in DI resolution without generating manifests. Used today for S3 providers in nw1.

### Implementation: Three levels of integration

**Level 1 — Manual bridge file (MVP):**

A JSON file checked into the repo that maps Terraform outputs to kix imports:

```json
// terraform-bridge.json
{
  "database_url": "postgresql://user:pass@10.0.1.5:5432/satchel",
  "gcs_bucket": "satchel-backups",
  "redis_host": "10.0.1.10"
}
```

```nix
# clusters/satchel-dev.nix
let
  tf = builtins.fromJSON (builtins.readFile ./terraform-bridge.json);
in {
  services.cloud-sql = kix.mkImport {
    from = packages.cloud-sql-import;
    config.connectionString = tf.database_url;
  };
}
```

This is manual but auditable. The bridge file is version-controlled, reviewed in PRs, and explicit about what flows from Terraform into kix.

**Level 2 — CI-generated bridge (better):**

A CI step that runs `terraform output -json > terraform-bridge.json` and commits it, or passes it as a build argument:

```yaml
    - name: Capture Terraform outputs
      run: |
        cd terraform/
        terraform output -json > ../terraform-bridge.json

    - name: Build with Terraform context
      run: nix build .#cluster-dev
```

The bridge file becomes a CI artifact that's always fresh. No manual maintenance.

**Level 3 — `mkTerraformImport` helper (nice-to-have):**

A kix helper that wraps the pattern:

```nix
services.cloud-sql = kix.mkTerraformImport {
  stateFile = ./terraform-bridge.json;  # or: stateKey = "database_url";
  package = packages.cloud-sql-import;
  mapping = {
    connectionString = "database_url";
    host = "database_host";
    port = "database_port";
  };
};
```

This is sugar over Level 1 — it doesn't change the mechanism, just makes the pattern discoverable.

### What the import package looks like

```nix
# packages/cloud-sql-import/default.nix
{ meta, options, build, ... }: {
  meta = {
    description = "Google Cloud SQL (imported from Terraform)";
    scope = "cluster";
    lifecycle = "stateful";
  };

  options = {
    connectionString = { type = "string"; description = "Full connection string"; };
    host = { type = "string"; default = ""; };
    port = { type = "int"; default = 5432; };
    database = { type = "string"; default = ""; };
  };

  build = { self, config, ... }: {
    # No manifests — this is an import-only package
    main.out = {
      connectionString = config.connectionString;
      host = config.host;
      port = config.port;
      database = config.database;
    };
  };
}
```

Consuming packages use `deps.database` and get `database.out.connectionString` — they don't know or care whether it's a StackGres pod or a Cloud SQL instance.

**Effort:** Level 1 is trivial (documentation + example). Level 2 is a CI pattern (medium). Level 3 is a small Nix helper.

---

## 5. Service Catalog Packages

### What's needed

Sam needs monitoring, logging, and secret management. These are "catalog" packages that wrap well-known Helm charts via `fromHelmChart`.

### Implementation approach: `fromHelmChart` wrapping

The pattern is established — several packages already use `fromHelmChart`. The work for each new catalog package:

1. Fetch the Helm chart via `fetchHelmChart`
2. Wrap with `fromHelmChart` to get raw resources
3. Add kix DI wiring (expose `out` properties, declare `deps`)
4. Add kix options for the most common configuration knobs
5. Wire into the `availablePackages` registry

**kube-prometheus-stack:**

```nix
# packages/kube-prometheus-stack/default.nix
{ meta, options, build, ... }: {
  meta = {
    description = "Prometheus + Grafana + Alertmanager monitoring stack";
    defaultAliases = [ "prometheus" "monitoring" "grafana" ];
    scope = "namespace";
  };

  options = {
    grafana.adminPassword = { type = "string"; default = "admin"; };
    prometheus.retention = { type = "string"; default = "15d"; };
    alertmanager.enable = { type = "bool"; default = true; };
  };

  deps = {
    storage = { optional = true; };        # for persistent prometheus data
    ingressNginx = { optional = true; };   # for grafana ingress
    clusterIssuer = { optional = true; };  # for grafana TLS
  };

  build = [
    ./chart.nix        # fromHelmChart wrapping
    ./grafana-di.nix   # DI-driven ingress/TLS for grafana (kix.expose pattern)
    ({ self, config, ... }: {
      main.out = {
        prometheusUrl = "http://${self.prometheusService.out.fqdn}:9090";
        grafanaUrl = "http://${self.grafanaService.out.fqdn}:3000";
        # Other packages check for prometheus injection to enable ServiceMonitors
      };
    })
  ];
}
```

**external-secrets-operator:**

```nix
# packages/external-secrets-operator/default.nix
{ meta, options, build, ... }: {
  meta = {
    description = "External Secrets Operator — sync secrets from external stores";
    defaultAliases = [ "external-secrets" "secret-store" ];
    scope = "namespace";
  };

  options = {
    provider = {
      type = "string";
      default = "gcp";  # gcp | aws | vault | azure
    };
  };

  build = [
    ./chart.nix
    ({ self, config, ... }: {
      main.out = {
        # Consumer packages can create ExternalSecret CRs referencing this store
        clusterSecretStoreName = self.clusterSecretStore.out.name;
        mkExternalSecret = { name, key, ... }: scope.mkResource {
          # ... helper to create ExternalSecret CR pointing at this store
        };
      };
    })
  ];
}
```

**Logging (Loki + promtail):**

Two packages: `loki` (log store) and `promtail` (log shipper). Promtail takes `deps.loki` and auto-wires the push URL. Loki exposes `out.pushUrl` for any log shipper.

### Sequencing

1. **kube-prometheus-stack** first — it's the most requested and enables the "if Prometheus exists, auto-enable metrics" DI pattern that already works
2. **external-secrets-operator** second — secret management is a hard requirement for any real deployment
3. **Logging stack** third — nice-to-have for MVP, Sam can use GKE's native Cloud Logging initially

**Effort per package:** Medium. The `fromHelmChart` wrapping is mechanical. The DI wiring and options design requires care to get right — these become API surface for all clusters using the package.

---

## 6. Multi-Environment Pattern

### What exists

`mkEnv` is fully functional. Multiple cluster definitions in one flake work. The gap is documentation and a reference implementation.

### Implementation

Create a reference example showing the two canonical patterns:

**Pattern A: Separate cluster definitions (recommended for Satchel)**

```
clusters/
├── satchel-dev.nix     # cluster-satchel-dev
└── satchel-prod.nix    # cluster-satchel-prod
```

Each cluster definition imports the same packages but with different configs:

```nix
# clusters/satchel-dev.nix
{ pkgs, ... }: {
  imports = [ pkgs.lib.flavors.gke ];
  cluster.name = "satchel-dev";
  cluster.domain = "dev.satchel.example";

  services.immich = {
    config.image.tag = "latest";  # dev: follow latest
    config.replicas = 1;
  };
}
```

```nix
# clusters/satchel-prod.nix
{ pkgs, ... }: {
  imports = [ pkgs.lib.flavors.gke ./satchel-base.nix ];
  cluster.name = "satchel-prod";
  cluster.domain = "satchel.example";

  services.immich = {
    config.image.tag = "v1.99.0";  # prod: pinned version
    config.replicas = 3;
  };
}
```

CI deploys based on branch: `dev` branch → `cluster-satchel-dev`, `main` → `cluster-satchel-prod`.

**Pattern B: `mkEnv` for shared-cluster environments**

When dev and prod share a physical cluster (cost saving), `mkEnv` stamps namespaces:

```nix
# clusters/satchel-shared.nix
mkEnv {
  environments = {
    dev = { config.replicas = lib.mkDefault 1; };
    prod = { config.replicas = lib.mkDefault 3; };
  };
  services = { ... };
}
```

This is more advanced and less relevant for Satchel (they have GKE credits for separate clusters).

**Effort:** Small. This is primarily documentation + a reference cluster definition. The machinery already works.

---

## 7. Deploy Target Verification

### Why it matters

Accidental cross-environment deploys are the #1 most damaging operator error. One wrong `--context` flag and dev code hits production. This is a safety feature that costs almost nothing to build and prevents catastrophic mistakes.

### Implementation

Already designed in the ROADMAP. The approach:

```nix
# clusters/satchel-prod.nix
cluster.deploy.allowedContexts = [ "gke_satchel-prod_us-central1_main" ];
```

At deploy time:

```rust
// cli/kix-cli/src/commands/deploy.rs (addition)
fn verify_target(cluster: &ClusterOutput, context: &str) -> Result<()> {
    if let Some(allowed) = &cluster.deploy_config.allowed_contexts {
        if !allowed.contains(&context.to_string()) {
            bail!(
                "Deploy target mismatch!\n\
                 Cluster '{}' allows contexts: {:?}\n\
                 Current context: '{}'\n\
                 \n\
                 If this is intentional, use --force-context to override.",
                cluster.name, allowed, context
            );
        }
    }
    Ok(())
}
```

The allowed contexts list lives in the cluster definition (version-controlled, reviewed in PR). No runtime configuration, no environment variables — the safety net is in the code.

**Effort:** Small. A few lines in `deploy.rs` + a new module option in `modules.nix`.

---

## 8. GKE Flavor Completeness

### Current state

`lib/flavors/gke.nix` exists and sets 8 capabilities. It's thin but correct.

### What's missing

Reviewing the file against GKE's actual feature set:

| Capability | In flavor | Notes |
|---|---|---|
| `managedControlPlane` | ✅ true | |
| `loadBalancer` | ✅ true | |
| `cni` | ✅ "gke-native" | |
| `networkPolicyAPI` | ✅ "k8s" | |
| `ingressController` | ✅ "gce" | Could be misleading — most users deploy ingress-nginx on GKE |
| `persistentStorage` | ✅ true | |
| `volumeSnapshots` | ✅ true | |
| `nodeAutoscaling` | ✅ false | Correct default |
| `rwxStorage` | ❌ missing | GKE Filestore provides RWX, but not by default |
| `daemonSets` | ❌ missing | Should be true (standard GKE allows DaemonSets) |
| `privilegedContainers` | ❌ missing | Depends on GKE Security Posture, default true |

### Implementation

Add missing capabilities. Also add `cluster.network` defaults for GKE:

```nix
# lib/flavors/gke.nix (additions)
cluster.capabilities.daemonSets = lib.mkDefault true;
cluster.capabilities.privilegedContainers = lib.mkDefault true;
cluster.capabilities.rwxStorage = lib.mkDefault false;  # requires Filestore addon

cluster.network = {
  podCidr = lib.mkDefault "10.0.0.0/14";        # GKE default
  serviceCidr = lib.mkDefault "10.4.0.0/20";     # GKE default
  dnsDomain = lib.mkDefault "cluster.local";
};
```

**Important note on `ingressController`:** GKE's default GCE ingress is rarely what users actually want — most deploy ingress-nginx or similar. The flavor should document this:

```nix
# Note: GKE ships with GCE ingress controller but most production
# clusters deploy ingress-nginx instead. Override with:
#   cluster.capabilities.ingressController = "nginx";
```

**Effort:** Small. Adding a few lines to the flavor file + verifying against GKE docs.

---

## Sequencing: What to Build in What Order

### Phase 0: Immediate wins (1-2 days each)

These are disproportionately high-value for minimal effort:

1. **`kix export`** — makes the exit story tangible
2. **Deploy target verification** — prevents the worst possible mistake
3. **GKE flavor completion** — 10 lines of Nix
4. **Multi-env documentation** — write up what already works

### Phase 1: CI pipeline (the "plan/apply" loop)

5. **GitHub Action composite** — the diff-as-PR-comment flow
6. **Snapshot-based CI diff** — offline diffing without cluster creds in PR
7. **SARIF export from `kix check`** — scorecard violations in code review (synergistic with CI)

### Phase 2: Service catalog (make it useful for a real cluster)

8. **kube-prometheus-stack package** — monitoring is table stakes
9. **external-secrets-operator package** — secrets are a hard requirement
10. **Loki + promtail packages** — logging

### Phase 3: Onboarding (make it approachable)

11. **`kix init`** — zero-to-building scaffold
12. **Terraform bridge documentation + helpers** — `mkImport` patterns for cloud resources
13. **Reference GKE cluster definition** — `clusters/example-gke.nix`

### What we explicitly defer

- **Operator/OCI transport** (doc 46) — Sam's model is push-based CI, not continuous reconciliation. The operator exists for later.
- **Connector/provider abstraction** — `mkImport` with manual bridge files is sufficient for MVP.
- **Topology-aware monitoring** (doc 49) — standard Prometheus alerting is fine; auto-derived alerting is a later differentiator.
- **Advanced compliance exports** (CycloneDX, SLSA, OSCAL) — SARIF alone covers the CI integration story; the rest is for enterprise sales later.

---

## Open Questions

1. **Snapshot storage in CI:** Where does the "last deployed" snapshot live between CI runs? Options: (a) Git artifact branch, (b) CI artifact storage (GitHub Actions cache), (c) OCI registry. GitHub Actions cache is simplest for MVP.

2. **`kix init` implementation language:** Rust (in the CLI), Nix (as a flake template), or shell script? Nix flake templates (`nix flake init -t kixpkgs#gke`) are the most idiomatic but require the user to already have Nix. The CLI could be a better UX if it also installs/configures Nix.

3. **Helm chart pinning for catalog packages:** How do we pin Helm chart versions in the `fromHelmChart` packages? Need to ensure reproducibility — a `kube-prometheus-stack` package should always produce the same output for the same inputs. This is likely already handled by `fetchHelmChart` with hash pinning, but worth verifying.

4. **Service catalog scope:** How many packages do we need before the MVP is "useful"? Sam's stack: Cloud SQL (Terraform), Redis (kix or Terraform), Firebase Auth (Terraform), GCS (Terraform), Prometheus (kix), logging (kix or GKE native). Minimum: monitoring + external-secrets. Nice-to-have: logging.

5. **GKE ingress controller default:** Should the GKE flavor default to `"gce"` (what GKE ships) or `"nginx"` (what most users deploy)? Current: `"gce"`. Recommendation: keep `"gce"` as the flavor default (it's what the platform provides), let `kix init` ask and override to `"nginx"` if the user chooses ingress-nginx.

---

## Implementation Progress

### Completed

- [x] **GKE flavor completion** — added `daemonSets`, `gpu`, `privilegedContainers`, `podSecurityEnforcement`, `rwxStorage`, `cluster.network.dnsDomain` to `lib/flavors/gke.nix`. Added inline docs about GCE vs ingress-nginx.
- [x] **Multi-env reference** — created `clusters/example-multi-env/` with `base.nix` (shared packages), `dev.nix` (relaxed config, latest tags), `prod.nix` (pinned versions, HA). Demonstrates Pattern A (separate cluster definitions sharing a base module).
- [x] **SARIF export plumbing** — full pipeline:
  - Nix: `flake.nix` now serializes `scorecardReport` as `kix-scorecard.json` in the activation result dir (conditional on scorecard being enabled)
  - Rust: `ClusterOutput` extended with `scorecard_report: Option<Value>`, `cli_backend.rs` reads the file from the result dir
  - CLI: `kix check --sarif` outputs SARIF 2.1.0 JSON. `kix check` now also shows a scorecard summary row (errors/warnings/info counts). SARIF includes rule definitions, findings with severity mapping, and logical locations (namespace/instance/resource).
  - GitHub integration: `kix check <cluster> --sarif > results.sarif` → `github/codeql-action/upload-sarif` displays findings as code review annotations.
- [x] **kube-prometheus-stack generification** — split `packages/kube-prometheus-stack/default.nix` into generic defaults (sensible resources, all selectors open, security context, dashboard sidecar, null alertmanager receiver) vs nw1-specific overrides (moved to `clusters/nw1/monitoring.nix` `config.values`: ingress, TLS, 400Gi storage, incident.io webhooks, priority classes, specific domains).

### In design (thinking)

- [ ] **Terraform bridge** — see expanded design below

---

## Appendix: Terraform Bridge — Design Thinking

### The fundamental tension

Terraform and kix operate at different levels of abstraction with different lifecycles:
- **Terraform:** cloud provider resources (VMs, databases, buckets, IAM). Slow to change, expensive to recreate, often stateful.
- **kix:** Kubernetes resources (Deployments, Services, ConfigMaps). Fast to change, cheap to recreate, mostly stateless.

The bridge needs to respect this asymmetry. Terraform outputs are *facts* from kix's perspective — kix doesn't manage them, it consumes them.

### Why `mkImport` is the right primitive

`mkImport` already models exactly this: "this thing exists outside my control, here are its properties." The DI system doesn't care whether `deps.database` is a StackGres pod in the same cluster or a Cloud SQL instance managed by Terraform. It just needs `database.out.connectionString`.

This is the correct abstraction level. We don't need:
- A Terraform provider inside kix (wrong scope — kix is a manifest compiler, not an IaC tool)
- Direct Terraform state parsing (fragile, couples to Terraform internals)
- A new resource type for external services (mkImport already handles this)

### The three-level approach refined

**Level 1: Static bridge file** — the user maintains a JSON file mapping Terraform outputs to kix imports. This is the right MVP because:
- It's explicit and auditable (code review catches changes)
- It's version-controlled (git history shows what changed when)
- It works offline (no Terraform state access needed during `nix build`)
- It's composable (different bridge files per environment)

The question is: where does the bridge file live? Three options:

1. **In the kix repo** — `terraform-bridge.json` next to cluster definitions. Simple, but duplicates Terraform state. Risk: goes stale.
2. **Generated by CI** — `terraform output -json > bridge.json` before `nix build`. Always fresh, but requires Terraform credentials in the kix CI pipeline.
3. **Nix flake input** — the bridge file is a separate git repo or artifact that the kix flake consumes as an input. Decoupled, but adds a flake input management step.

Recommendation: **Option 2 for MVP** with option 1 as a fallback for local development. CI runs `terraform output -json` → filters to relevant outputs → writes bridge file → `nix build` reads it. For local development, the developer maintains a `terraform-bridge.local.json` (gitignored) or uses a stale checked-in version.

**Level 2: Typed import packages** — create a small library of common cloud resource import patterns:

```nix
# packages/cloud-sql-import/default.nix — Google Cloud SQL as a kix import
#
# Usage in cluster definition:
#   services.database = kix.mkImport {
#     from = packages.cloud-sql-import;
#     config = {
#       connectionString = tf.database_url;
#       host = tf.database_host;
#     };
#   };

{ scope, lib, kix }: {
  meta = {
    description = "Google Cloud SQL (imported from Terraform)";
    defaultAliases = [ "postgres" "database" ];
    scope = "cluster";
    lifecycle = "stateful";
  };
  options = {
    connectionString = lib.mkOption { type = lib.types.str; };
    host = lib.mkOption { type = lib.types.str; default = ""; };
    port = lib.mkOption { type = lib.types.int; default = 5432; };
  };
  build = { self, config, ... }: {
    main.out = {
      connectionString = config.connectionString;
      host = config.host;
      port = config.port;
    };
  };
}
```

The key insight: these import packages are *thin wrappers* that make `mkImport` outputs match the `out` interface that consuming packages expect. If `packages/immich` expects `deps.postgres.out.connectionString`, the Cloud SQL import package must expose that field. This is DI interface conformance, not a new mechanism.

Import packages for common cloud resources:
- `cloud-sql-import` — Cloud SQL / RDS (matches `stackgres-cluster` out interface)
- `managed-redis-import` — Memorystore / ElastiCache (matches `valkey` out interface)
- `object-storage-import` — GCS / S3 (matches `hetzner-s3` / `ovh-s3` out interface)
- `managed-dns-import` — Cloud DNS / Route53 (matches `dns` alias interface)

**Level 3: `mkTerraformImport` helper** — sugar that combines Level 1 + Level 2:

```nix
# In cluster definition
let
  tf = kix.loadTerraformBridge ./terraform-bridge.json;
in {
  services.database = tf.import {
    package = packages.cloud-sql-import;
    mapping = {
      connectionString = "database_url";
      host = "database_host";
      port = "database_port";
    };
  };
}
```

`kix.loadTerraformBridge` reads the JSON file and returns a helper with an `import` function that:
1. Reads the specified keys from the bridge file
2. Applies the mapping to the import package's config
3. Wraps in `kix.mkImport`

This is small enough to implement in `lib/` (maybe `lib/terraform.nix`, ~30 lines).

### Security considerations

The bridge file may contain sensitive values (database URLs with passwords, API keys). Options:
- **Don't put secrets in the bridge file** — use Kubernetes Secrets for credentials, bridge file only for non-secret connection metadata (host, port, bucket name). This is the recommended pattern.
- **Encrypt the bridge file** — agenix or sops-nix can encrypt at rest. The bridge file is decrypted during CI build.
- **Reference secrets by name** — bridge file contains Secret *names*, not values. kix packages reference the Secret resource. This is already how external-secrets-operator works.

Recommendation: **non-secret metadata only in the bridge file**. Secrets flow through external-secrets-operator (GCP Secret Manager → K8s Secret → pod env var). The bridge file carries hosts, ports, bucket names — not passwords.

### What this means for Satchel MVP

Sam's stack:
- Cloud SQL → `cloud-sql-import` package + bridge file with `host`/`port`/`database`
- GCS bucket → `object-storage-import` with `bucketName`
- Firebase Auth → not a kix concern (client-side SDK, no K8s resources needed)
- Redis (if on Memorystore) → `managed-redis-import` with `host`/`port`

The MVP work:
1. Document the bridge file pattern (Level 1) — 1 day
2. Create 2-3 import packages matching existing `out` interfaces — 1 day
3. Add `kix.loadTerraformBridge` helper — half day
4. Reference example in `clusters/example-gke.nix` showing the full pattern — half day
