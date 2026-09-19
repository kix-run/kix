# 2026-09-19 · `kix/lib/core/availability.nix` · `meta.availability.max` caps the whole instance, so a package with one single-replica controller also loses hard spread on its quorum stores.

`kix/packages/openebs` declares `max = "pod"` for the three mayastor
control-plane agents, and the same ceiling lowers etcd and NATS from
`DoNotSchedule` to `ScheduleAnyway` on the zone key: a three-member
quorum on three zones wants the hard constraint. The ladder resolves one
level per instance (`eval/instance.nix`); a per-workload ceiling, or a
way for a package to say "this workload honours the level, that one
cannot", would state it correctly.
