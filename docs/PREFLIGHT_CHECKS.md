# Kix v2: Pre-flight Check Tools

Kix generates YAML at eval time. Before deploying, we can run offline validation
tools against the output. This table covers what's available.

## Tool comparison

Ordered by usefulness to Kix.

| Tool | Local YAML | CRD support | Offline | Focus | Status |
|---|---|---|---|---|---|
| **kubeconform** | Yes | Yes (JSON Schema) | Yes | Schema validation — catches typos, wrong types, missing fields. The only offline tool that validates CRDs. | Active |
| **kyverno CLI** | Yes | N/A (policy engine) | Yes | Custom org policy written in YAML. This is where graph-derived policies (network policy rules, ordering constraints) would be enforced. | Active |
| **pluto** | Yes | N/A | Yes | API deprecation detection. Single-purpose, fast. Catches deprecated apiVersions before they hit a cluster upgrade. | Active |
| **trivy config** | Yes | No | Yes (after DB dl) | Security misconfiguration (runs as root, no securityContext, etc.). Broad coverage, auto-detects file types. | Active |
| **kubescape** | Yes | No | Yes (after dl) | Compliance frameworks (NSA, MITRE, CIS). Different angle from trivy — frameworks vs. individual misconfigs. | Active |
| **polaris** | Yes | Partial (custom JSON Schema checks) | Yes | Best practices + auto-fix. Custom checks in JSON Schema (more accessible than Rego). | Active |
| **kube-score** | Yes | No | Yes | Best practices (probes, resource limits, security context). Lightweight, no config needed. Overlaps with polaris. | Active |
| **conftest** | Yes | N/A (policy engine) | Yes | Custom policy in Rego. More powerful than kyverno for cross-tool use (Terraform, Dockerfiles too), but higher setup cost. | Active |
| **kubectl --dry-run=client** | Yes | No | Partial (needs kubeconfig) | Basic syntax/structure check. Minimal value beyond kubeconform. | Built-in |
| **kubectl --dry-run=server** | No (needs cluster) | Yes | No | Full API validation including admission webhooks. Authoritative but requires a cluster. | Built-in |
| **kubecost/opencost** | No | N/A | N/A | Cost monitoring for running clusters. Not a validator. | N/A |
| **kubeval** | Yes | No | Yes | Schema validation. **Replaced by kubeconform.** | Dead |
| **datree** | Was yes | Was partial | Was yes | Policy engine. Archived June 2024, do not adopt. | Dead |

## Recommended stack for Kix

A `kix check` command could chain these in order:

1. **Kix eval-time checks** — cross-resource validation, dependency cycles, duplicate names (no YAML needed)
2. **kubeconform** — schema correctness including CRDs
3. **pluto** — deprecated API detection
4. **kyverno CLI** — graph-derived policies + org-specific rules
5. **trivy config** or **kubescape** — security/compliance
6. **polaris** or **kube-score** — best-practice lint

Steps 1 is free (already happens during eval). Steps 2-6 run against the
generated YAML directory. All fully offline.
