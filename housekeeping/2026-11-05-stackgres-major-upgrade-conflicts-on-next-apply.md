# 2026-11-05 · `kix/packages/stackgres-cluster` · After a StackGres major upgrade, Kix's next apply conflicts over `spec.postgres.version`.

A `majorVersionUpgrade` SGDbOps makes the StackGres operator write the new major into the SGCluster's `spec.postgres.version`, under its own field manager. Kix still owns that field, so its next apply stops on an ownership conflict until the cluster definition names the new major too. Ceding the field (`ownership.cede`) would let the operator keep it, but then a definition that still says `17` on a cluster running 18 deploys with no warning.

Decision required from Adam: cede `spec.postgres.version` in `stackgres-cluster`, or keep the conflict as the prompt to update the definition.
