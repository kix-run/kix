# 61 — Compliance Exports: SARIF, SBOM, SLSA, OSCAL

**Status:** Draft
**Related:** `60_scorecard_rules_design.md` (scorecard rule system), `54_activation_signing.md` (cryptographic provenance), `25_package_meta_warnings.md` (diagnostics), `business_discussions/11_idp_gap_analysis.md` (IDP gap analysis)

---

## Context

kix produces an unusual amount of structured data at build time: every resource, every dependency edge, every package version, every container image, the full DAG with content hashes. Most IDP and compliance tools struggle to *collect* this data — kix has it as a mathematical byproduct of compilation.

The gap is export: turning this internal data into formats that auditors, CI systems, compliance platforms, and security tools understand. This document designs four export formats (ordered by impact) and maps them to five regulatory frameworks.

---

## 1. SARIF — Scorecard Findings Export

### What is SARIF

SARIF (Static Analysis Results Interchange Format) is an OASIS standard for reporting findings from static analysis tools. JSON format, well-specified schema. Adopted by GitHub Code Scanning, VS Code, Semgrep, Trivy, Snyk, SonarQube, and 100+ tools.

### Why SARIF matters for kix

GitHub and GitLab **natively ingest SARIF** and display findings as PR annotations. If `kix check` outputs SARIF, scorecard violations appear directly in code review — no custom GitHub Action UI needed. This is the single highest-leverage export: it turns the scorecard into a CI-native experience with zero integration work for the user.

### SARIF structure mapped to kix

A SARIF document has `runs`, each containing `tool` metadata, `results` (findings), and `rules` (definitions):

```json
{
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "version": "2.1.0",
  "runs": [{
    "tool": {
      "driver": {
        "name": "kix",
        "version": "0.1.0",
        "informationUri": "https://kix.dev",
        "rules": [
          {
            "id": "security/nonRoot",
            "name": "NonRootContainers",
            "shortDescription": { "text": "All containers must run as non-root" },
            "defaultConfiguration": { "level": "error" },
            "properties": { "tags": ["security", "cis-benchmark"] }
          }
        ]
      }
    },
    "results": [
      {
        "ruleId": "security/nonRoot",
        "level": "error",
        "message": {
          "text": "container 'immich-server' does not set runAsNonRoot"
        },
        "locations": [{
          "physicalLocation": {
            "artifactLocation": {
              "uri": "packages/immich/default.nix"
            }
          },
          "logicalLocations": [{
            "fullyQualifiedName": "production/immich/immich-deployment",
            "kind": "resource"
          }]
        }],
        "properties": {
          "namespace": "production",
          "package": "immich",
          "resource": "immich-deployment",
          "resourceKind": "Deployment"
        }
      }
    ],
    "taxonomies": [{
      "name": "CIS Kubernetes Benchmark",
      "taxa": [
        { "id": "5.2.6", "name": "Minimize the admission of root containers" }
      ]
    }]
  }]
}
```

### Key mapping decisions

| kix concept | SARIF field | Notes |
|---|---|---|
| Rule name (`security.nonRoot`) | `ruleId` | Slash-separated: `security/nonRoot` |
| Effective severity | `level` | SARIF uses: `error`, `warning`, `note` (maps from kix `error`, `warning`, `info`) |
| Package source file | `physicalLocation` | Points to the package `.nix` file — enables GitHub to annotate the source |
| Resource identity | `logicalLocations` | `namespace/instance/resource-name` as `fullyQualifiedName` |
| Rule tags | `properties.tags` on rule | Enables filtering in GitHub Security tab |
| CIS/NIST mapping | `taxonomies` | Optional — maps rules to compliance framework controls |

### Implementation: `kix check --format sarif`

The `kix check` command (see `60_scorecard_rules_design.md`) already produces a structured findings list. SARIF export is a serialization of that list:

1. Collect all scorecard findings (the `findings` list from the scorecard evaluator)
2. Collect all rule definitions (for the `rules` array in the SARIF tool driver)
3. Map finding severity to SARIF levels
4. Resolve source locations: each package instance traces back to its package directory (known from `instCfg.package`)
5. Serialize as SARIF JSON

**CLI:**
```bash
kix check nw1 --format sarif > results.sarif

# GitHub Actions integration:
# - uses: github/codeql-action/upload-sarif@v3
#   with:
#     sarif_file: results.sarif
```

**Effort estimate:** Small. The scorecard system produces the data; SARIF is a JSON serialization format. The main work is mapping source locations correctly.

---

## 2. CycloneDX SBOM — Software Bill of Materials

### What is CycloneDX

CycloneDX is an OASIS standard for Software Bills of Materials. JSON and XML schemas. Lists every component in a software system with version, provenance, license, and dependency relationships. Required by US Executive Order 14028 and the incoming EU Cyber Resilience Act (2027).

### Why CycloneDX matters for kix

kix has **complete** knowledge of every component at build time:
- Every package instance and its version
- Every container image reference (including digest if pinned)
- Every Helm chart source and version
- Every Nix flake input with its locked hash
- The full dependency graph between all of the above

This is genuinely hard for other tools. Trivy scans container images but doesn't know the K8s wiring. Backstage knows the catalog but not the actual deployed versions. kix knows everything because it *produces* everything.

### CycloneDX structure mapped to kix

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "version": 1,
  "metadata": {
    "timestamp": "2026-03-31T14:22:00Z",
    "tools": {
      "components": [{
        "type": "application",
        "name": "kix",
        "version": "0.1.0"
      }]
    },
    "component": {
      "type": "platform",
      "name": "cluster-nw1",
      "version": "activation-abc123def456",
      "description": "kix cluster nw1",
      "properties": [
        { "name": "kix:activation-hash", "value": "abc123def456..." },
        { "name": "kix:cluster-provider", "value": "hetzner" }
      ]
    }
  },
  "components": [
    {
      "type": "application",
      "name": "immich",
      "version": "v2.0.0",
      "purl": "pkg:kix/immich@v2.0.0",
      "properties": [
        { "name": "kix:namespace", "value": "production" },
        { "name": "kix:owner", "value": "app-team" },
        { "name": "kix:identity-hash", "value": "1234abcd..." }
      ]
    },
    {
      "type": "container",
      "name": "ghcr.io/immich-app/immich-server",
      "version": "v1.99.0",
      "purl": "pkg:docker/immich-app/immich-server@v1.99.0?repository_url=ghcr.io",
      "hashes": [{
        "alg": "SHA-256",
        "content": "abc123..."
      }]
    },
    {
      "type": "library",
      "name": "ingress-nginx-helm-chart",
      "version": "4.9.0",
      "purl": "pkg:helm/ingress-nginx/ingress-nginx@4.9.0",
      "properties": [
        { "name": "kix:source", "value": "fromHelmChart" }
      ]
    }
  ],
  "dependencies": [
    {
      "ref": "immich",
      "dependsOn": ["stackgres-cluster", "valkey", "persistent-volume-claim"]
    },
    {
      "ref": "stackgres-cluster",
      "dependsOn": ["stackgres-operator", "storage-classes"]
    }
  ]
}
```

### Component mapping

| kix concept | CycloneDX component | `purl` scheme |
|---|---|---|
| Package instance | `type: "application"` | `pkg:kix/name@version` |
| Container image | `type: "container"` | `pkg:docker/org/image@tag` |
| Helm chart source | `type: "library"` | `pkg:helm/repo/chart@version` |
| Nix flake input | `type: "library"` | `pkg:nix/input@rev` (custom scheme) |
| Cluster itself | `metadata.component` (`type: "platform"`) | — |

### Data sources

All data is available at eval time:

| Data | Source | Available in |
|---|---|---|
| Package name + version | `meta.nix` (`peekPackageMeta`) | `kix-packages.json`, `instanceInfo` |
| Container images | Manifest fields: `spec.template.spec.containers[].image` | Resource manifests |
| Helm chart refs | `fromHelmChart` calls record chart name/version | Package build context |
| Nix flake inputs | `flake.lock` | Available in eval via `builtins.getFlake` |
| Dependency graph | Store-path DAG / `kix.dev/depends-on` | StoreGraph in Rust CLI |
| Owner | `meta.owner` | Package meta |
| Identity hashes | Store path first 32 chars | StoreGraph |

### Implementation: `kix sbom`

**Nix side:** A new eval pass after `allInstancesList` is built. Walk all instances, extract:
- Package meta (name, version, owner)
- All container image refs from manifests (scan `spec.template.spec.containers[].image` and `initContainers`)
- Helm chart sources (from `_meta.helmChart` if we annotate `fromHelmChart` results)
- Nix flake inputs (from `flake.lock`)
- Dependency edges (from the resolution index or store-path context)

**Rust side:** The `StoreGraph` already has packages + resource paths + dependency edges. The SBOM generation can run entirely in Rust by walking the StoreGraph and parsing manifest fields.

**Recommendation:** Build in Rust. The StoreGraph already has the graph; we just need to extract image refs from manifests and serialize as CycloneDX JSON.

**CLI:**
```bash
kix sbom nw1 > sbom.json
kix sbom nw1 --format cyclonedx-json  # explicit (default)
kix sbom nw1 --format spdx-json       # alternative format (later)
```

**Effort estimate:** Medium. The data exists; the work is extracting image refs from manifests, building the component list, and serializing. The CycloneDX JSON schema is well-documented.

---

## 3. SLSA Provenance — Build Attestation

### What is SLSA

SLSA (Supply-chain Levels for Software Artifacts) is a framework by Google/OpenSSF defining levels of supply chain security. The provenance format is an in-toto attestation that says "this artifact was built by this builder from this source with these parameters."

### Why SLSA matters for kix

Nix already provides near-SLSA Build Level 3 properties:
- **L1:** Documented build process (flake.nix)
- **L2:** Hosted build (if using CI), authenticated provenance
- **L3:** Hardened build platform — Nix builds are hermetic (sandboxed, no network during build, locked inputs)

The gap to actual SLSA L3 compliance is *attestation* — generating and signing the provenance document. kix can do this cheaply because the activation hash IS the build output, and signing is designed in `54_activation_signing.md`.

### SLSA provenance mapped to kix

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{
    "name": "cluster-nw1-activation",
    "digest": {
      "blake3": "abc123def456..."
    }
  }],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://kix.dev/build/v1",
      "externalParameters": {
        "cluster": "nw1",
        "flakeRef": "github:org/kixpkgs#cluster-nw1",
        "flakeLock": "sha256:locked-hash..."
      },
      "internalParameters": {
        "nixVersion": "2.24.0",
        "kixVersion": "0.1.0",
        "system": "x86_64-linux"
      },
      "resolvedDependencies": [
        {
          "uri": "github:org/kixpkgs",
          "digest": { "gitCommit": "abc123..." }
        }
      ]
    },
    "runDetails": {
      "builder": {
        "id": "https://github.com/org/kixpkgs/actions/runs/12345"
      },
      "metadata": {
        "invocationId": "ci-run-12345",
        "startedOn": "2026-03-31T14:20:00Z",
        "finishedOn": "2026-03-31T14:22:00Z"
      }
    }
  }
}
```

### How this connects to activation signing (doc 54)

Document 54 designs signing the activation root hash with Ed25519. SLSA provenance wraps this in a standardized attestation format:

1. `kix build` produces the activation with its content hash (already exists)
2. `kix attest` (new) generates the SLSA provenance document (JSON above)
3. `kix sign` (from doc 54) signs the provenance with Ed25519
4. The signed provenance is stored alongside the activation (annotation, or as a separate artifact)
5. `kix verify` (from doc 54) verifies both the signature and the provenance

The key insight: **the activation hash IS the SLSA subject digest.** No additional hashing needed. Nix's content addressing provides the subject; SLSA provides the attestation format; Ed25519 provides the signature.

### Implementation: `kix attest`

```bash
# Generate SLSA provenance for a cluster build
kix attest nw1 --builder-id "https://github.com/org/repo/actions/runs/123" > provenance.json

# Sign the provenance
kix sign --key /path/to/private-key provenance.json

# Verify
kix verify --public-key /path/to/public-key provenance.json
```

**Data sources:**
- Subject: activation identity hash (from `StoreGraph` or activation CR)
- Flake ref: `flake.nix` path and lock hash
- Git commit: `git rev-parse HEAD`
- Builder ID: passed as CLI argument (CI provides this)
- Nix version: `nix --version`
- Timestamps: wall clock

**Effort estimate:** Small-medium. The provenance document is a JSON template filled with data that's already available. The signing infrastructure is designed in doc 54. The main work is the attestation CLI command and the in-toto envelope format.

---

## 4. OSCAL — Compliance Framework Mapping

### What is OSCAL

OSCAL (Open Security Controls Assessment Language) is a NIST standard for expressing security controls, assessment plans, and results in machine-readable format (JSON, XML). It maps controls from frameworks (NIST 800-53, SOC 2, ISO 27001) to system implementations and evidence.

### Why OSCAL matters

OSCAL is the bridge from "we have scorecard results" to "here's our compliance documentation." An auditor doesn't want SARIF output. They want: "Control CC6.1 requires change management. Here's how kix satisfies it, and here's the evidence."

OSCAL is gaining traction:
- FedRAMP is migrating to OSCAL for all authorization packages (US government)
- **Lula** (by Defense Unicorns) is specifically a Kubernetes OSCAL compliance tool
- Growing adoption in financial services (DORA compliance)

### OSCAL layers mapped to kix

OSCAL has several document types. kix would produce two:

#### Component Definition

"Here's what kix does and which controls it satisfies."

This is a **static document**, authored once and updated when capabilities change. It says: "kix's scorecard rule `security.nonRoot` satisfies CIS Benchmark 5.2.6 and contributes to SOC 2 CC6.1."

```json
{
  "component-definition": {
    "uuid": "...",
    "metadata": { "title": "kix IDP", "version": "0.1.0" },
    "components": [{
      "uuid": "...",
      "type": "software",
      "title": "kix Kubernetes Compiler",
      "description": "Compiler-based IDP with build-time policy enforcement",
      "control-implementations": [{
        "uuid": "...",
        "source": "https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final",
        "description": "NIST 800-53 controls satisfied by kix",
        "implemented-requirements": [
          {
            "uuid": "...",
            "control-id": "cm-2",
            "description": "Baseline Configuration — kix cluster definitions are the baseline. Every deployment is a content-addressed activation traceable to a specific build."
          },
          {
            "uuid": "...",
            "control-id": "cm-3",
            "description": "Configuration Change Control — all changes go through kix build pipeline. Scorecard rules enforce policies. Activation signing provides cryptographic proof of authorized builds."
          },
          {
            "uuid": "...",
            "control-id": "sa-11",
            "description": "Developer Testing — scorecard rules evaluate security properties at build time. Findings are reported in SARIF format. Failed error-level rules block deployment."
          }
        ]
      }]
    }]
  }
}
```

#### Assessment Results

"Here's the evidence from our latest build."

This is a **generated document**, produced by `kix audit`. It contains the actual scorecard results, SBOM data, and provenance attestation as evidence for each control.

```json
{
  "assessment-results": {
    "uuid": "...",
    "metadata": {
      "title": "kix Compliance Assessment — cluster nw1",
      "last-modified": "2026-03-31T14:22:00Z"
    },
    "results": [{
      "uuid": "...",
      "title": "Build-time assessment",
      "start": "2026-03-31T14:20:00Z",
      "end": "2026-03-31T14:22:00Z",
      "findings": [
        {
          "uuid": "...",
          "title": "CM-2: Baseline Configuration",
          "description": "Cluster nw1 activation abc123 is content-addressed and deterministic. All 42 package instances have identity hashes. SBOM attached.",
          "target": {
            "type": "objective-id",
            "target-id": "cm-2",
            "status": { "state": "satisfied" }
          }
        },
        {
          "uuid": "...",
          "title": "SA-11: Security Testing",
          "description": "15 scorecard rules evaluated. 3 errors, 8 warnings, 4 info. See SARIF report for details.",
          "target": {
            "type": "objective-id",
            "target-id": "sa-11",
            "status": { "state": "not-satisfied" },
            "description": "3 error-level findings remain unresolved"
          }
        }
      ],
      "observations": [
        {
          "uuid": "...",
          "description": "SARIF report with 15 findings",
          "relevant-evidence": [{
            "href": "./scorecard-results.sarif",
            "description": "Full scorecard findings in SARIF format"
          }]
        },
        {
          "uuid": "...",
          "description": "CycloneDX SBOM with 42 components",
          "relevant-evidence": [{
            "href": "./sbom.json",
            "description": "Software Bill of Materials"
          }]
        }
      ]
    }]
  }
}
```

### Implementation: `kix audit`

`kix audit` is the umbrella command that produces a complete compliance package:

```bash
kix audit nw1 --framework soc2 --output-dir ./compliance/

# Produces:
#   compliance/
#     scorecard-results.sarif      # SARIF findings
#     sbom.json                    # CycloneDX SBOM
#     provenance.json              # SLSA provenance
#     assessment-results.json      # OSCAL assessment
#     audit-report.md              # Human-readable summary
```

**Effort estimate for OSCAL:** Medium-high. The Component Definition is a one-time authored document. The Assessment Results generator needs to map scorecard findings to framework controls, which requires a control-to-rule mapping table. The tooling (Lula, NIST oscal-cli) can validate the output.

**Recommendation:** Start with a single framework mapping (SOC 2 or NIST 800-53). Add others incrementally. The OSCAL generation is templated — once the first framework works, adding a second is mostly mapping work.

---

## 5. Regulatory Framework Mapping

For each framework: what evidence it requires, what kix data satisfies it, and how mature the mapping is.

### SOC 2 (AICPA Trust Services Criteria)

**What it is:** Audit framework for service organizations. Five trust criteria: Security, Availability, Processing Integrity, Confidentiality, Privacy. Most tech companies pursue SOC 2 Type II (covers a period, not a point in time).

**Format:** No machine-readable standard. Auditors accept screenshots, exported reports, policy documents, JSON with explanatory cover sheets. Vanta/Drata/Secureframe automate collection.

**Control-to-kix mapping:**

| SOC 2 Control | What auditors want | kix evidence |
|---|---|---|
| **CC6.1** Change management | Proof that changes are authorized, tested, approved | Activation CR history (every deploy is a hash, traceable to a git commit + PR approval). SLSA provenance. Scorecard results showing policy checks passed. |
| **CC6.2** System component inventory | List of all system components | CycloneDX SBOM — every package, image, chart, with versions and hashes |
| **CC6.8** Vulnerability management | Evidence of vulnerability scanning | Scorecard rules for image pinning, no-latest-tag, no-privileged. Future: CVE scanning integration on SBOM components. |
| **CC7.1** Detection of unauthorized changes | Drift detection, integrity monitoring | `kix health` drift detection with content-hash comparison. Activation signing proves authorized state. |
| **CC7.2** Monitoring system components | Continuous monitoring evidence | Scorecard `observability.hasServiceMonitor` rule. Network policy generation showing isolation. Topology-aware monitoring (future, doc 49). |
| **CC8.1** Authorization of changes | Changes are authorized before implementation | Git PR approval + SLSA provenance (builder ID = CI, triggered by approved PR). Scorecard error-level rules block unauthorized patterns. |

**How to deliver:** `kix audit --framework soc2` generates a markdown report with:
- Section per relevant control
- Narrative description of how kix satisfies it
- Links to evidence artifacts (SARIF, SBOM, provenance)
- Gaps identified (controls kix can't satisfy — e.g., employee background checks)

**Maturity:** SOC 2 evidence acceptance is flexible. Auditors are increasingly comfortable with JSON/API evidence if accompanied by a narrative. kix's evidence (SARIF + SBOM + signed provenance) exceeds what most companies provide today. Main gap: SOC 2 requires evidence over a *period* (Type II), not a single point. Need activation history over time.

### ISO 27001:2022

**What it is:** International standard for Information Security Management Systems (ISMS). Annex A contains 93 controls across 4 themes. Certification requires an external audit.

**Format:** No machine-readable standard. Evidence is policy documents, screenshots, audit logs, configuration exports.

**Key Annex A controls kix maps to:**

| ISO 27001 Control | What auditors want | kix evidence |
|---|---|---|
| **A.8.9** Configuration management | Baseline configs established and maintained | Cluster definitions ARE the baselines. Activation hashes prove state. Deterministic builds prove reproducibility. |
| **A.8.25** Secure development lifecycle | Security built into development | Scorecard rules enforce security policies at build time. Prevention by construction, not detection. |
| **A.8.8** Management of technical vulnerabilities | Vulnerability management process | SBOM enables vulnerability scanning. Scorecard rules for image hygiene. |
| **A.8.22** Segregation of networks | Network segmentation | Auto-generated NetworkPolicies from DI graph (doc 37, `netpol.nix`). Provable: the compiler derived the policies. |
| **A.5.9** Inventory of information assets | Asset inventory | CycloneDX SBOM = complete infrastructure asset inventory, automatically maintained. |
| **A.8.32** Change management | Changes are controlled | Same evidence as SOC 2 CC6.1. |
| **A.8.33** Test information | Test evidence | Scorecard results = test evidence. "Every build runs 15 security checks." |

**Maturity:** ISO 27001 auditors are generally less tech-savvy than SOC 2 auditors. The narrative report is more important than the raw data. `kix audit --framework iso27001` should produce a heavily narrative document with evidence *attached*, not evidence-first.

### DORA (EU Digital Operational Resilience Act)

**What it is:** EU regulation (effective January 2025) for financial entities. Covers ICT risk management, incident reporting, resilience testing, and third-party risk management. Applies to ~180,000 entities (banks, insurance, investment firms, payment providers).

**Format:** Partially machine-readable. Incident reports have XML schemas. ICT third-party register has structured templates. Risk management framework is principles-based.

**DORA requirements mapped to kix:**

| DORA Article | Requirement | kix evidence |
|---|---|---|
| **Art. 9** Protection and prevention | ICT systems are secure and resilient | Scorecard rules enforce security standards at build time. Network policies derived from DI graph. |
| **Art. 9(4)(c)** Mechanisms for detecting anomalous activities | Drift detection | `kix health` compares content hashes against intended state. Operator reconcile heals drift. |
| **Art. 10** Detection | Continuous monitoring for ICT incidents | Topology-aware monitoring (doc 49) auto-generates alerts from dependency graph. |
| **Art. 11** Response and recovery | Capacity to recover from ICT disruptions | `kix rollback` provides instant recovery to previous activation. Deterministic builds mean any historical state is reproducible. |
| **Art. 12** Backup policies | Backup and restoration procedures | Scorecard rule `reliability.hasBackup` checks stateful packages. Velero integration with `out.withBackup`. |
| **Art. 28** ICT third-party risk register | Register of all ICT service providers | CycloneDX SBOM lists all third-party components. Can be mapped to DORA's register template (structured spreadsheet). |
| **Art. 9(4)(d)** Configuration management | Baseline configurations established and maintained | Cluster definitions = baseline. Activation hashes = proof. Identical to ISO 27001 A.8.9 evidence. |

**Unique DORA angle:** DORA specifically calls out "cryptographic controls" (Art. 9(4)(b)) and "mechanisms for detecting anomalous activities" (Art. 9(4)(c)). kix's content-addressed Merkle DAG and drift detection are *exactly* what DORA envisions — but expressed in formal regulation language. The marketing angle is strong: "kix provides DORA-compliant configuration management and drift detection as a byproduct of compilation."

**Maturity:** DORA is new (effective 2025). The technical standards (RTS/ITS) are still being interpreted. Early movers who can demonstrate compliance tooling have an opportunity. The SBOM-to-register mapping and the cryptographic state proof are differentiators.

### NIS2 (EU Network and Information Security Directive)

**What it is:** EU directive expanding cybersecurity requirements to essential and important entities across 18 sectors. Transposed into national law by October 2024. Applies to ~160,000 entities.

**Format:** Principles-based, no specific evidence format. National implementations vary.

**NIS2 requirements mapped to kix:**

| NIS2 Requirement | Article | kix evidence |
|---|---|---|
| Risk management measures | Art. 21(2)(a) | Scorecard rules as risk management measures. SARIF report as evidence. |
| Supply chain security | Art. 21(2)(d) | CycloneDX SBOM. SLSA provenance. Nix's locked inputs. |
| Security in acquisition, development, maintenance | Art. 21(2)(e) | Build-time policy enforcement. Scorecard rules. |
| Vulnerability handling and disclosure | Art. 21(2)(e) | SBOM enables vulnerability tracking. Future: CVE database integration. |
| Cryptography and encryption | Art. 21(2)(h) | Activation signing (doc 54). Content-addressed state proof. |
| Business continuity / disaster recovery | Art. 21(2)(c) | `kix rollback`. Deterministic builds. Backup scorecard rules. |

**Maturity:** NIS2 is principles-based and national implementations vary. The evidence is more about demonstrating a *process* than producing specific artifacts. kix's contribution is making the process provable and automated.

### EU Cyber Resilience Act (CRA) — Preview

**What it is:** EU regulation (applies from 2027) requiring software products sold in the EU to meet cybersecurity requirements and provide SBOMs. Applies to all "products with digital elements."

**Why it matters for kix:** The CRA will legally require SBOMs for software sold in the EU. kix's CycloneDX export becomes a *legal compliance requirement*, not just a nice-to-have. Additionally, the CRA requires vulnerability handling processes — the SBOM + CVE tracking pipeline becomes mandatory.

**Maturity:** The regulation is finalized but not yet in effect. Early SBOM tooling is a market advantage.

---

## 6. Implementation Sequence

Ordered by impact, dependency, and effort:

### Phase 1: SARIF (weeks 1-3)

**Depends on:** Scorecard rule system (doc 60)
**Produces:** `kix check --format sarif`
**Why first:** Highest immediate impact. GitHub/GitLab native. Every CI user gets value. No new data collection — just serialization of scorecard findings.

**Tasks:**
1. Define SARIF serialization for the scorecard findings struct (Rust, `kix-cli`)
2. Map rule IDs to SARIF rule format
3. Resolve source file locations (package directory from instance config)
4. Add `--format sarif` flag to `kix check`
5. Write a sample GitHub Actions workflow

### Phase 2: CycloneDX SBOM (weeks 3-6)

**Depends on:** StoreGraph (exists), manifest parsing (exists)
**Produces:** `kix sbom`
**Why second:** Required by US EO and upcoming EU CRA. Unique kix advantage (complete build-time knowledge). Feeds into OSCAL and compliance reports.

**Tasks:**
1. Extract container image refs from manifests (walk all resources, parse `spec.template.spec.containers[].image`)
2. Extract Helm chart sources (annotate `fromHelmChart` results with source metadata, or parse from package meta)
3. Parse `flake.lock` for Nix input provenance
4. Build CycloneDX component list + dependency graph from StoreGraph
5. Serialize as CycloneDX 1.6 JSON
6. Add `kix sbom` CLI command

### Phase 3: SLSA Provenance (weeks 6-8)

**Depends on:** Activation signing (doc 54, at least the hash computation part)
**Produces:** `kix attest`
**Why third:** Completes the supply chain story. Small effort since it's mostly a JSON template + the signing from doc 54.

**Tasks:**
1. Define SLSA provenance template
2. Fill build metadata (git commit, flake lock hash, nix version, builder ID)
3. Generate in-toto attestation envelope
4. Integrate with activation signing from doc 54
5. Add `kix attest` CLI command

### Phase 4: OSCAL + Compliance Reports (weeks 8-14)

**Depends on:** SARIF (Phase 1), SBOM (Phase 2), SLSA (Phase 3)
**Produces:** `kix audit --framework <soc2|iso27001|dora>`
**Why last:** Requires the other artifacts as evidence. Higher effort (framework mapping tables). But highest value for regulated market customers.

**Tasks:**
1. Author OSCAL Component Definition for kix (one-time, static document)
2. Define control-to-rule mapping tables for SOC 2
3. Build OSCAL Assessment Results generator (consumes SARIF + SBOM + SLSA)
4. Generate human-readable audit report (markdown/PDF)
5. Add `kix audit` CLI command
6. Add ISO 27001 and DORA mapping tables

---

## 7. Open Questions

1. **SBOM scope:** Should the SBOM include the kix operator and CLI themselves as components, or only the cluster content? For EU CRA compliance, the full toolchain may need to be declared.

2. **Continuous vs. point-in-time:** SOC 2 Type II requires evidence over a period. `kix audit` produces a snapshot. Need a story for "here are all audits from the last 12 months." Solution: store audit artifacts in git (alongside the cluster definition) so history is git history.

3. **CVE integration:** The SBOM lists container images. Cross-referencing with CVE databases (Grype, Trivy) would identify known vulnerabilities. Should this be a kix feature (`kix scan`) or an external tool that consumes the SBOM? Recommendation: external tool consumes SBOM. Don't rebuild Trivy.

4. **OSCAL tooling maturity:** OSCAL is still relatively new. Should we validate output with NIST's `oscal-cli`? Yes — add to CI.

5. **Vanta/Drata integration:** These compliance platforms have APIs for evidence ingestion. Should `kix audit` push directly to them, or produce artifacts that the user uploads? Recommendation: produce artifacts first. API integration later when we have design partners using these platforms.

6. **SPDX support:** CycloneDX and SPDX are competing SBOM formats. Some industries (automotive, telecom) require SPDX. Should we support both? Recommendation: CycloneDX first (better K8s ecosystem fit). SPDX conversion via `syft` as a documented workaround. Native SPDX if demand materializes.
