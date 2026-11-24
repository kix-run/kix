# 2026-11-24 · `cli/kix-core/src/eval/nix.rs` · An evaluation error inside a cluster is reported as "uses a Kix library older than Kix", which sends the user to `kix upgrade`.

A fixture build entry in `clusters/test-nats.nix` was called without the
named argument `lib` ("function 'anonymous lambda' called without required
argument 'lib'"). `kix check nats` printed "cluster 'nats' uses a Kix
library older than Kix 0.10.0-rc.6" and "Run `kix upgrade`". Only `-vv`
showed the real error. `missing_index` treats any failure to read the
activation index of a listed cluster as `NoActivationIndex`, so an error
thrown while the index is evaluated takes the same path.
