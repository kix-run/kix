# 2026-09-27 · `kix deploy` · The number of failed resources before a halt varies between runs.

`how-to/adoption-helm-takeover/conflict.json` records `1 failed, 6 cancelled`,
and a fresh live capture on 2026-09-27 recorded `2 failed, 5 cancelled`, with a
second conflict warning for `ServiceAccount/reflector@reflector-system`.
`halt-on-first-failure` cancels the remaining resources only after the applies
already in flight finish, so the count depends on timing. The live capture
for this page cannot be stable while the output depends on that timing.
