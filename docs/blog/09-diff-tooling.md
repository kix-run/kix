---
title: "Diff Tooling: Trust but Verify"
date: 2026-03-18
series: 9
commits:
  - 97a099b  # feat: cluster diff tooling for migration verification
  - e6ef705  # feat: kix-diff based on service and color
---

# Diff Tooling: Trust but Verify

*2026-03-18 -- Post 9*

---

You have 357 manifests. Your live cluster is running. How do you know they match?

You could `kubectl apply --dry-run=server` and squint at the output. You could diff individual files by hand. Neither scales. When you are migrating 26 packages across dozens of namespaces, you need something that compares **everything** and tells you **exactly** what differs.

## The two-script pipeline

The answer is two scripts that split the problem in half.

**kix-dump.py** pulls live cluster state into a directory of normalized YAML files. One file per resource, organized by namespace. It strips the noise that Kubernetes adds at runtime -- `managedFields`, `resourceVersion`, `uid`, `creationTimestamp`, `status` -- so you are comparing declared intent, not server bookkeeping. Secret data gets stripped too. Only metadata and type survive.

The dump has four modes. `--match-kix` fetches exactly the resources your kix build declares -- the tightest comparison. `--managed` finds everything with the `app.kubernetes.io/managed-by=kix` label. `--namespaces` targets specific namespaces. `--all` grabs everything. For migration work, `--all` is how you discover what exists. `--match-kix` is how you verify what you have built.

**kix-diff.py** takes a kix output directory and a dump directory and produces a structured markdown report. It walks both trees, matches resources by namespace/name/kind, and reports differences using JSON-path notation:

```
## cert-manager/deployment-cert-manager
  ~ .spec.template.spec.containers[0].resources.limits.cpu:
      cluster: "500m"
      kix:     "250m"
  + .spec.strategy.type: 'RollingUpdate'    (cluster only)
  - .spec.template.spec.nodeSelector: ...   (kix only)
```

No unified diffs. No walls of red and green YAML. Each difference is a single path with the two values side by side. You can scan 50 resources in a minute and know exactly where they diverge.

The report groups resources into sections: **identical**, **modified**, **kix-only**, **cluster-only**. It also runs **fuzzy rename detection** -- if a resource moved namespaces or changed names, the diff engine finds the closest structural match and shows the comparison anyway. This catches the case where you renamed a Deployment from `my-app` to `my-app-web` and want to confirm the spec is otherwise identical.

## The iteration loop

The workflow is tight:

1. Build: `nix build .#cluster-prod`
2. Dump: `./scripts/kix-dump.py --all cluster-dump/`
3. Diff: `./scripts/kix-diff.py ./result cluster-dump/`
4. Read the report. Fix the package. Go to step 1.

This is how the production migration was verified. Build, dump, diff, fix. Each cycle narrowed the gap between what kix produced and what the cluster was actually running. Some differences were bugs -- a missing resource limit, a wrong port number. Others were intentional -- kix producing cleaner defaults than the hand-written originals. The diff report made it obvious which was which.

## Service-level coloring

As the migration progressed, the raw diff report got long. 26 packages, hundreds of resources. The diffs were later enhanced to group output by service and color-code the results. **Green** means the service matches exactly. **Yellow** means minor differences -- usually cosmetic labels or annotation ordering. **Red** means structural divergence that needs investigation. Scanning the full report became a matter of looking for red sections instead of reading every line.

## The real insight

Generating manifests is half the problem. The other half is proving they are correct. Without diff tooling, you are in "I think this is right" territory. With it, you can see every field that differs between your generated output and the running cluster. The confidence gap between those two states is enormous.

The diff scripts turned migration from a leap of faith into an engineering process. Dump, diff, fix, repeat -- until the report says what you expect it to say.
