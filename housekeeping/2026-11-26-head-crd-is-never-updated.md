# 2026-11-26 · `cli/kix/src/cluster/head/crd.rs` · Kix creates the `activationheads.kix.run` definition once and never updates it.

`ensure_crd` creates the definition when it is absent and leaves one that
exists as it is. A later release that adds a version or a field to the
head's schema needs a way to update the definition on clusters that have
the old one. The schema keeps unknown fields under `status` today, so a new
field survives, but a new served version would not appear.
