# 2026-09-27 · `cli` · `kix deploy` fails a Deployment update on a crash-looping pod from the ReplicaSet it is replacing.

Lane g4 redeployed `clusters/test-harbor.nix` with a fix for
`harbor-registry` and `harbor-exporter`, whose old pods were in
CrashLoopBackOff. The deploy failed both at once with "CrashLoopBackOff after
4 restarts" while the new pods were three seconds old; both new pods went
Ready within a minute and the next deploy passed. Readiness reads pods of the
outgoing ReplicaSet, so a deploy that fixes a crash loop reports the crash
loop it just fixed and cancels everything downstream.
- Hit again 2026-09-28 while redeploying openebs to kind, on
  `openebs-localpv-provisioner` and then `openebs-obs-callhome`, both in
  the openebs package, since deleted.
