# 2026-09-18 · `kix/lib/scope/builders.nix` · `workload.rawSelector` recurses when the cycle runs through the manifest.

BEST-PRACTICES §7.3 and §12.6 offer `rawSelector` as the escape from a
Service/workload cycle. `mkWorkload` seals the manifest (validators,
netpol interceptors) before `// { rawSelector = ...; }` is applied, so a
Service that the workload's own ConfigMap references hits infinite
recursion reading it. Harbor breaks its core/jobservice cycle with a
shared literal selector instead, and the docs still point at
`rawSelector`.
