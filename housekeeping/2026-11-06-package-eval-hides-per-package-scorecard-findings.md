# 2026-11-06 · `kix/package-eval.nix` · There is no way to ask for one scorecard rule's findings across every package as data.

The check evaluates every package with the full rule set, but it exposes
only `names` and the private `settings` the packages need, so a rule
author who wants to know which packages a new rule flags has no way to
ask. Until 2026-11-14 the findings could be read as `trace: warning:
[scorecard:<rule>]` lines in the check's stderr, and the library no longer
prints those. A scan that rebuilds the clusters outside package-eval cannot
reuse `settings`, so 43 of 82 packages fail to evaluate in it. Hit while
adding `architecture.controllerRequiresCrds`.
