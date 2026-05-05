#!/usr/bin/env python3
"""Pretty-printer for netpol-edge-audit.nix output.

Reads the JSON emitted by

    nix eval --impure --json \
      --extra-experimental-features 'pipe-operators flakes nix-command' \
      -f scripts/netpol-edge-audit.nix

and prints a per-cluster / per-instance summary. Exit code is non-zero
if any instance has `missingFromScope` edges — i.e. if Phase C would
silently drop an ingress rule that today's cluster-level pass catches.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <audit.json>", file=sys.stderr)
        return 2

    data = json.loads(Path(argv[1]).read_text())

    any_missing = False
    total_missing = 0
    total_extra = 0

    for cluster_name in sorted(data):
        cluster = data[cluster_name]
        miss = cluster["totalMissing"]
        extra = cluster["totalExtra"]
        total_missing += miss
        total_extra += extra
        status = "OK " if miss == 0 else "!! "
        print(
            f"{status}{cluster_name}: "
            f"{len(cluster['instances'])} instances, "
            f"missing={miss} extra={extra}"
        )
        if miss == 0 and extra == 0:
            continue
        for inst in cluster["instances"]:
            if not inst["missingFromScope"] and not inst["extraInScope"]:
                continue
            any_missing = any_missing or bool(inst["missingFromScope"])
            print(
                f"  {inst['instName']}: "
                f"ground={inst['groundCount']} scope={inst['scopeCount']} "
                f"workloads={inst['workloadCount']}"
            )
            for e in inst["missingFromScope"]:
                print(
                    f"    MISS  {e['sourceNamespace']}/{json.dumps(e['sourceSelector'])}"
                    f"  ->  {e['targetNamespace']}/{e['targetService']}"
                )
            for e in inst["extraInScope"]:
                print(
                    f"    EXTRA {e['sourceNamespace']}/{json.dumps(e['sourceSelector'])}"
                    f"  ->  {e['targetNamespace']}/{e['targetService']}"
                )

    print()
    print(f"totals: missing={total_missing} extra={total_extra}")
    if total_missing == 0:
        print(
            "Phase C audit: GREEN — scope-time extraction is ≥ processInstance extraction."
        )
        print("Safe to delete generateIngressPolicies.")
    else:
        print("Phase C audit: RED — some edges only visible post-fixpoint.")
        print(
            "Deleting generateIngressPolicies would drop ingress rules for the MISS entries above."
        )

    return 1 if any_missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
