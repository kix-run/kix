# 2026-10-03 · `kix/lib/scope/builders.nix` · `scope.mkServiceRef` and `scope.mkSecretRef` replace `out`, so a reference has no `out.identityHash`.

Every resource built with `mkResource` publishes `out.identityHash`, which tests compare with a consumer's `kix.run/depends-on`. The two reference builders return the marker with a new `out` that drops it, so `kix/lib/tests/units/rabbitmq.nix` digs the hash out of `builtins.getContext ref.out.name` instead. Keeping the marker's `identityHash` in the new `out` would remove that workaround.
