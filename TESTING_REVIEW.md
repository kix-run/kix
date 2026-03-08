# Testing Strategy Review: kixpkgs

**Date:** 2026-03-08
**Scope:** Eval-time assertions, schema validation, parity testing, test coverage, CI readiness

---

## Executive Summary

The kixpkgs testing strategy has three layers: **eval-time assertions** (Nix-based structural checks), **schema validation** (kubeconform), and **parity testing** (Helm vs kix comparison). The approach is sound but reveals **three critical gaps**:

1. **Parity strategy sustainability**: Comparing against Helm is useful for migration but creates long-term friction for intentional divergences
2. **Test coverage is sparse**: Only 4 test cases defined; no negative tests, option interactions, or error scenarios
3. **CI integration incomplete**: Parity tests require Helm + network; no GitHub Actions workflow exists

This review prioritizes recommendations by implementation cost and impact.

---

## 1. Eval-Time Assertions (checks.cluster-example)

### Findings

**Strengths:**
- Clear intent: validates that intent merging works across charts
- Placed at the right boundary: before runCommand, so Nix aborts on assertion failure with readable error messages
- Low overhead: Nix laziness means assertions execute only once during flake evaluation
- Well-structured: registry and monitoring assertions are logically separated

**Gaps:**

1. **Registry assertions are shallow**: Only check that endpoints exist and have non-empty hosts/ports. They don't validate:
   - Port numbers are correct (coredns should be 53, valkey should be 6379, sentinel 26379)
   - Protocol matches intended use (DNS over UDP/TCP, Redis over TCP)
   - All required endpoints are populated (e.g., no sentinel endpoint should exist for non-sentinel mode)

2. **Monitoring assertions don't validate ServiceMonitor structure**:
   - Assert that `monitoring-valkey-servicemonitor` exists but don't check:
     - Its selector matches the service
     - Its portName matches the service's port name
     - Its interval/scrapeTimeout are reasonable
   - Assert that per-chart monitor was suppressed but don't validate why or what triggered suppression

3. **No assertions on cluster-level defaults**:
   - Namespace propagation not checked
   - Domain suffix application not verified
   - Release name consistency across resources not validated
   - Labels from `config.cluster.labels` not verified

4. **No negative assertions**:
   - Don't check that disabled features are absent (e.g., if `sentinel.enabled = false`, sentinel resources shouldn't exist)
   - No validation that optional features don't leak into mandatory resources

### Recommendations (Priority: Medium)

| Recommendation | Implementation Cost | Impact |
|---|---|---|
| **Extend registry assertions** with port/protocol validation | Low | Medium — catches configuration errors early |
| **Add namespace/domain/labels assertions** | Low | High — validates critical intent merging |
| **Add negative assertions** for disabled features | Medium | Medium — catches feature flag bugs |
| **Structured assertion helper** (e.g., `mkAssert`) | Medium | Low — improves readability, reduces duplication |

---

## 2. Schema Validation (checks.schema-*)

### Findings

**Strengths:**
- Cubeconform integration is solid: catches invalid apiVersions, missing required fields, type errors
- Good coverage: coredns, valkey (base + sentinel + full), and cluster-example all validated
- Skips ServiceMonitor (CRD without built-in schema)

**Gaps:**

1. **CRD validation is missing**: ServiceMonitor is Prometheus Operator's CRD. Currently skipped because kubeconform doesn't have Prometheus Operator schemas built-in. This is a known limitation, but:
   - No fallback validation (e.g., checking essential fields manually)
   - No documentation of what schemas are skipped and why
   - No plan to add CRD schemas when Prometheus Operator adds them

2. **Custom CRD schemas not integrated**: If the project adds custom CRDs later (NetworkPolicy aggregation, custom status, etc.), there's no clear path to validate them:
   - kubeconform can load schemas from custom CRDS/ directories, but this isn't documented
   - No mechanism to generate or maintain schemas

3. **Schema version mismatch not detected**: kubeconform validates against K8s API versions, but doesn't warn if a manifest targets an older API version than the current schema set (e.g., a Deployment using apps/v1beta1)

4. **No validation of Nix-specific quirks**:
   - Empty fields (null, {}, []) are stripped in normalize.py but kubeconform may accept them (false confidence)
   - removeNulls is applied at serialization but schema validation happens after that

### Recommendations (Priority: High for CRDs, Low for others)

| Recommendation | Implementation Cost | Impact |
|---|---|---|
| **Document skipped schemas** in flake.nix comments | Very Low | Low — operational clarity |
| **CRD schema support** (custom Prometheus Operator + future CRDs) | Medium | High — will become critical as project evolves |
| **Schema version pinning** in flake.nix (explicit K8s version) | Low | Medium — prevents API drift surprises |

---

## 3. Parity Testing (verify-parity.py)

### Findings

**Strengths:**
- Sophisticated normalization: handles Helm-specific prefixes, labels, annotations, ConfigMap whitespace, array ordering
- Good UX: click CLI, cached chart downloads, detailed diffs, summary reporting
- Flexible: supports single checks and batch runs from cases.yaml
- Smart ignore-missing: allows skipping known divergences (e.g., Secret/valkey for Bitnami's auto-generated secrets)

**Critical Issues:**

1. **Long-term sustainability problem**: Parity testing assumes kix *should* match Helm output. But as the project matures, kix will intentionally diverge:
   - Custom admission webhooks may transform resources
   - Intent merging (registry, monitoring) adds resources Helm doesn't have
   - Removing deprecated fields Helm still includes
   - Using newer K8s APIs when base chart uses old versions

   **When divergence becomes intentional, "parity" isn't the right goal anymore.** The test becomes misleading.

2. **Normalization is fragile and incomplete**:
   - Hardcoded HELM_RELEASE_PREFIX assumes release name is "release-name". If users override it, normalization breaks
   - Whitespace normalization in ConfigMaps is ad-hoc (regex-based). Doesn't handle all edge cases (YAML multiline strings, shell scripts with significant whitespace)
   - Array sorting by name/protocol only works for some array types (doesn't handle nested sorts, e.g., in volumeMounts.subPath)
   - Mount path trailing slash normalization assumes single "/" is meaningful; doesn't validate paths are absolute

3. **Test case coverage is minimal**:
   - coredns: only 1 test case (defaults)
   - valkey: only 3 test cases (base, sentinel, full)
   - No tests for:
     - Custom values (CPU limits, replicas, custom ConfigMap)
     - Error scenarios (invalid options, missing dependencies)
     - Option interactions (sentinel + metrics, custom registry endpoints)
     - Multi-chart interactions (coredns + valkey together with intent merging)

4. **No validation of intent merging in parity tests**:
   - Parity tests compare individual charts. Cluster-example is tested separately but parity isn't checked against multi-chart Helm composition
   - Registry endpoints and cross-cutting monitoring aren't validated as "matching Helm composition patterns"

5. **Helm chart dependencies aren't tested**:
   - Bitnami charts may have sub-dependencies (e.g., redis for sentinel). If those change, parity breaks silently
   - No lock file or version pinning beyond cases.yaml

### Recommendations (Priority: HIGH — this is critical for long-term maintainability)

| Recommendation | Implementation Cost | Impact |
|---|---|---|
| **Shift parity strategy** from "match Helm" to "regression against baseline" | High | CRITICAL — makes long-term testing sustainable |
| **Create behavioral spec** separate from Helm output | High | CRITICAL — documents what kix *should* do |
| **Enhance test case coverage** (at least 10+ cases per chart) | Medium | High — catches option bugs early |
| **Normalize by release name parameter** instead of hardcoded "release-name-" | Low | Medium — handles custom release names |
| **Validate intent merging in parity tests** (multi-chart scenarios) | Medium | Medium — ensures composition doesn't break |

---

## 4. Test Coverage Gaps

### Missing Scenarios

| Scenario | Why Important | Current State |
|---|---|---|
| **Invalid config (error cases)** | Validates error messages are readable | Not tested |
| **Option interactions** | Detects conflicting/dependent options | Not tested (e.g., sentinel without replication) |
| **Custom values** | Validates kix respects user config | Partially (3 valkey cases) |
| **Multi-chart interactions** | Validates intent merging at scale | Only 1 cluster-example check, no parity |
| **Drift from Helm** | Validates intentional divergences | Not defined (no baseline) |
| **Resource naming** | Validates names don't collide across charts | Not tested |
| **Label/annotation propagation** | Validates cluster-level labels reach all resources | Not tested (only intent-level assertions) |
| **NetworkPolicy generation** | Cross-cutting module skeleton exists but no tests | Not tested |

### Recommendations (Priority: Medium-High)

1. **Create negative test cases**: valkey without replication (should fail), coredns with conflicting options
2. **Add intent-level regression tests**: Baseline file for expected registry/monitoring structure
3. **Option interaction matrix**: Document which options are compatible, generate test matrix
4. **Multi-chart composition tests**: At least 3-5 cluster configs with different feature combinations

---

## 5. CI Readiness

### Current State
- Checks run in `nix flake check` (fast, no external dependencies)
- Parity tests are manual: `./scripts/verify-parity.py coredns all`
- No GitHub Actions workflow

### Challenges for CI Integration
1. **Parity tests require**:
   - Helm CLI + network access (pull charts from registries)
   - Python 3.11+ (uv shebang)
   - Nix (to build packages)
   - Caching (chart downloads, Nix store)

2. **Currently unsustainable**:
   - All tests in flake.nix must be deterministic and hermetic
   - Parity tests violate this (network dependency, Helm state)
   - Running parity in CI would slow feedback loop significantly

3. **No signal on intentional divergence**:
   - Without a behavioral spec, CI can't distinguish "parity broken because intentional divergence" from "parity broken because bug"

### Recommendations (Priority: High)

| Recommendation | Implementation Cost | CI Impact |
|---|---|---|
| **Split checks into fast (flake) + slow (script)** | Low | Improves feedback speed |
| **Document which parity tests are mandatory vs optional** | Low | Clarifies CI requirements |
| **Create GitHub Actions workflow** | Medium | Enables automated testing |
| **Cache Helm chart downloads** in CI | Low | Reduces flakiness, speeds up |
| **Baseline parity tests** against known-good manifests | Medium | Makes intentional divergence explicit |

---

## 6. Inside Nix vs Outside Nix Boundary

### Current Split
- **Inside Nix** (`flake.nix` checks): eval-time assertions, kubeconform schema validation
- **Outside Nix** (`verify-parity.py`): Helm template rendering, normalization, diffing

### Assessment
**This boundary is correct for speed, but wrong for completeness.**

**Why it's correct:**
- Nix checks are fast (no external network, hermetic, incremental)
- Parity tests are slow (Helm download, template rendering, normalization)
- Separating them allows fast feedback in development (flake check) and thorough validation in CI (parity script)

**Why it's incomplete:**
- Eval-time assertions can't validate behavioral equivalence (only structure)
- Schema validation can't check application-level logic (only K8s API conformance)
- Parity tests assume Helm is the source of truth (not sustainable long-term)
- No integration between layers: assertions don't inform parity tests, parity results don't inform assertions

### Recommendations (Priority: Medium)

1. **Strengthen eval-time assertions** to catch more structural issues
2. **Add post-schema validation** for application logic (e.g., "is this safe to deploy?")
3. **Define behavioral specs** independent of Helm (makes outside/inside boundary meaningful)
4. **Link test layers**: parity failures should update behavioral spec, assertions should validate spec

---

## Prioritized Action Plan

### Phase 1: Immediate (1-2 weeks)
1. **Extend eval-time assertions** with port/protocol/namespace/labels validation (Medium effort, high confidence)
2. **Document skipped schemas** (CRDs) in flake.nix (Trivial effort, good hygiene)
3. **Add 5-10 test cases** per chart (CPU/memory limits, replicas, custom values) (Medium effort, high immediate value)
4. **Normalize release name in parity script** (Low effort, prevents future bugs)

### Phase 2: Short-term (3-4 weeks)
1. **Create behavioral spec document** (what kix *should* do vs Helm) (High effort, critical for long-term)
2. **GitHub Actions workflow** for fast checks + optional parity (Medium effort, unblocks CI)
3. **Negative test cases** (invalid configs, conflicting options) (Medium effort, good hygiene)
4. **Intent merging regression tests** (validate registry/monitoring without parity) (Medium effort, validates core feature)

### Phase 3: Medium-term (ongoing)
1. **CRD schema support** (custom Prometheus Operator, future CRDs) (Medium effort, prevents future issues)
2. **Multi-chart interaction tests** (5+ cluster scenarios) (Medium effort, validates composition)
3. **Monitoring.nix tests** (network policy generation, cross-cutting concerns) (Medium effort, complete coverage)

---

## Summary Table

| Category | Finding | Severity | Effort | Impact |
|---|---|---|---|---|
| **Eval-time assertions** | Shallow validation | Medium | Low | High |
| **Schema validation** | CRD skipping undocumented | Low | Low | Low |
| **Parity strategy** | Unsustainable long-term | HIGH | High | Critical |
| **Test coverage** | 4 cases for 2 charts | High | Medium | High |
| **CI integration** | Missing GitHub Actions | Medium | Medium | High |
| **Boundary (inside/outside Nix)** | Correct, incomplete | Medium | Medium | Medium |

---

## Questions for Future Work

1. **Behavioral spec**: What should kix do differently than Helm, and why?
2. **Intentional divergences**: Which behaviors should kix diverge from Helm, and when?
3. **Multi-chart maturity**: How many charts will kix support? Does current architecture scale?
4. **CRD strategy**: Will kix define custom CRDs, or only use standard K8s + Prometheus Operator?
5. **Parity exit strategy**: At what point do we stop comparing against Helm?
