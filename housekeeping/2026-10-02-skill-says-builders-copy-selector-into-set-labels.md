# 2026-10-02 · `.claude/skills/kix-migration/SKILL.md` · The skill says workload builders copy the selector into the pod labels, but they do so only when the template sets no labels.

The paragraph after the scope table says `mkDeployment` and the other
workload builders "copy `spec.selector.matchLabels` to
`spec.template.metadata.labels`". `mkWorkload` in
`kix/lib/scope/builders.nix` uses the selector only when the template has no
`labels`; a template that sets upstream labels (an operator's pods, which
its runtime Services select) must merge `scope.selectorLabels` itself, or
`checkSelectorSubset` fails the build.
