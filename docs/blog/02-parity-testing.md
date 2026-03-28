---
title: "Parity Testing: Proving Nix Can Replace Helm"
date: 2026-03-07
date_end: 2026-03-08
series: 2
commit: 7bf95e2  # feat: multi-variant parity testing for Helm migrations
---

# Parity Testing: Proving Nix Can Replace Helm

*2026-03-07 to 2026-03-08 -- Post 2*

---

So you've written a Nix package that produces Kubernetes manifests. You claim it replaces a Helm chart. Why should anyone believe you?

This is the trust problem. Helm charts have years of battle-testing behind them. Your Nix package has a weekend. You can stare at the YAML output and convince yourself it looks right, but "looks right" does not cut it when you are talking about hundreds of lines of manifests across multiple resource types. You need proof. Not "similar" output -- **byte-for-byte identical YAML after normalization**.

## Starting with a concrete test

Here is what a test case looks like for the Valkey package. In a `cases.yaml` file alongside the test fixtures, you declare the Helm chart reference, its version, and the variants you want to verify:

```yaml
chart: oci://registry-1.docker.io/bitnamicharts/valkey
chart-version: "3.0.2"
ignore-missing:
  - Secret/valkey

cases:
  valkey: {}
  valkey-sentinel:
    values: sentinel.yaml
  valkey-full:
    values: full.yaml
```

Each case maps a Nix flake attribute (like `valkey-sentinel`) to a Helm values file. The `ignore-missing` field handles resources that Helm generates but your Nix package intentionally skips -- in this case, a Secret that gets managed outside the chart.

The default case uses no custom values at all. That is your baseline: does the Nix package match Helm's default output? The sentinel case enables Valkey's high-availability sentinel mode. The full case turns on every feature. If parity holds across all three, you have covered the important configuration surface.

## The verification loop

The logic is straightforward. For each case:

1. Run `helm template` against the cached chart with the specified values file.
2. Run `nix build` for the corresponding flake attribute.
3. **Normalize** both outputs -- strip ordering differences, cosmetic labels, and formatting noise.
4. Walk both resource trees structurally and diff them. Zero differences means parity.

In pseudocode:

```
for each case in cases.yaml:
    helm_resources = helm_template(chart, values_file)
    nix_resources  = nix_build(flake_attr)
    normalize(helm_resources)
    normalize(nix_resources)
    assert structural_diff(helm_resources, nix_resources) == []
```

The structural comparison is important. A naive string diff would flag reordered dictionary keys or different JSON indentation as failures. The tool instead walks both data trees by JSON path, comparing values semantically. Only real differences -- a missing field, a changed port number, a wrong label -- get reported.

## The tooling

The whole thing lives in a single Python script, `verify-parity.py`, with a UV shebang line at the top:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
```

No virtualenv setup. No requirements.txt. Just run the script and UV handles the rest. It uses Click for the CLI, giving you two commands: `check` for a single case and `all` to run every case in a `cases.yaml` file. The output is color-coded -- green for MATCH, yellow for DIFFERS, red for MISSING -- so you can scan results quickly.

Running all Valkey cases looks like:

```
./scripts/verify-parity.py all valkey
```

The script pulls the Helm chart once (caching it locally), then iterates through every case, printing a summary at the end: `7/7 passed` or a list of failures.

## Multi-chart coverage

Valkey was the first package to get parity tests, but the framework is chart-agnostic. CoreDNS followed with its own `cases.yaml` covering default configuration, Prometheus metrics, custom ServiceAccounts, PodDisruptionBudgets, and HPA variants. Same script, same workflow, same confidence.

Each chart's test directory sits under `tests/<chart>/` with the `cases.yaml` and any custom Helm values files. Adding a new chart to the parity suite means writing a `cases.yaml` and the corresponding Nix package -- the testing infrastructure does not care what chart you are wrapping.

## Why this matters

Luca and I built this framework because you simply cannot hand-verify the output of a Kubernetes manifest generator. A single Valkey deployment with sentinel mode produces dozens of resources -- StatefulSets, Services, ConfigMaps, ServiceAccounts, RBAC rules. Missing one `matchLabels` selector or getting a port number wrong means a broken deploy that might not fail until traffic hits it.

**Parity testing turns "I think this is right" into "I can prove this is right."** Every time you change the Nix package, you re-run the suite. If the diff is empty, you have not broken anything. If it is not empty, you see exactly which resource and which field diverged.

With Valkey and CoreDNS both achieving full parity across all variants, the question shifted from "can Nix replace Helm?" to "what should we migrate next?"
