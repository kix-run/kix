# 2026-10-01 · `kix/lib/rules/reliability.nix` · `reliability.boundedResources` warns on every package that leaves out a CPU limit on purpose, and a package cannot record why.

Some packages leave the CPU limit out of their `resources` default because
upstream sets none, with a comment saying so (descheduler). The rule
still prints "missing resource settings: limits.cpu" for each such instance
on every build, including `every-package-evaluates`, so the warning is noise
there and a real omission looks the same. Only a cluster-wide
`scorecard.ruleOverrides` can silence it.
