# 2026-09-27 · `kix deploy` · A first deploy reports its Activation as configured because the record already exists.

`ActivationRecord::create` (`cli/kix/src/cluster/ops/record.rs`) applies the
Activation record and marks it Deploying before the apply loop runs. When the
plan's own Activation node is applied later, the object is already there, and
the deploy prints `~ Activation/<name> configured` where a first deploy
should read `+ ... created`. The doc comment on `create_record` says that
later apply is an unchanged no-op, which the output contradicts. Seen in the
live captures of `kix deploy` for tutorials 02, 04 and 06.
