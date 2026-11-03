# 2026-11-03 · `kix/packages/cnpg-cluster` · At `zone`, a new instance's join job can make its volume in the wrong zone.

The spread counts pods labelled `cnpg.io/podRole=instance`, and CloudNativePG's join job has no such label, so the spread never moves the job. With zone-bound storage the claim binds in the zone where the job ran. If that zone already holds more instances than the spread allows, the new instance stays Pending. `node` avoids this with required per-host anti-affinity; `zone` cannot use the same rule, because several instances may share a zone.
