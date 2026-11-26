#!/usr/bin/env bash
# Write the build of each test cluster named below as a fixture for the
# `operator_graphs` tests in `src/cluster/graph.rs`. Each fixture keeps what
# the delete order reads: kind, name, namespace, the identity hash and
# `kix.run/depends-on`, a binding's subjects and roleRef, the Service each
# webhook of a webhook configuration calls, a network policy's pod selector,
# and a workload's serviceAccountName and pod labels. CustomResourceDefinitions are left out to keep the files
# small, since no edge that the tests check passes through one.
#
# usage: cli/kix/tests/fixtures/operator-graphs/record.sh (from the repository
# root, with `kix` on PATH or KIX set to the command to run)
set -euo pipefail

FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIX="${KIX:-kix}"

for cluster in cert-manager velero external-secrets; do
  "$KIX" build "$cluster" -o json | python3 -I -c '
import json, sys
templates = {
    "Deployment": ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "DaemonSet": ["spec", "template", "spec"],
    "Job": ["spec", "template", "spec"],
    "CronJob": ["spec", "jobTemplate", "spec", "template", "spec"],
}
kept = []
for m in json.load(sys.stdin):
    if m["kind"] == "CustomResourceDefinition":
        continue
    meta = m["metadata"]
    out = {"apiVersion": m["apiVersion"], "kind": m["kind"], "metadata": {"name": meta["name"]}}
    if "namespace" in meta:
        out["metadata"]["namespace"] = meta["namespace"]
    notes = {k: v for k, v in meta.get("annotations", {}).items()
             if k in ("kix.run/identity-hash", "kix.run/depends-on")}
    if notes:
        out["metadata"]["annotations"] = notes
    for field in ("subjects", "roleRef"):
        if field in m:
            out[field] = m[field]
    for field in ("podSelector", "endpointSelector"):
        if field in m.get("spec", {}):
            out.setdefault("spec", {})[field] = m["spec"][field]
    if "webhooks" in m:
        out["webhooks"] = [
            {"clientConfig": {"service": w["clientConfig"]["service"]}}
            for w in m["webhooks"]
            if "service" in w.get("clientConfig", {})
        ]
    path = templates.get(m["kind"])
    if path and m["apiVersion"] in ("apps/v1", "batch/v1"):
        spec = m
        for key in path:
            spec = spec.get(key, {})
        at = out
        for key in path[:-1]:
            at = at.setdefault(key, {})
        at[path[-1]] = {k: spec[k] for k in ("serviceAccountName",) if k in spec}
        template = m
        for key in path[:-1]:
            template = template.get(key, {})
        labels = template.get("metadata", {}).get("labels")
        if labels:
            at.setdefault("metadata", {})["labels"] = labels
    kept.append(out)
json.dump(kept, sys.stdout, indent=1, sort_keys=True)
print()
' > "$FIX/$cluster.json"
done
