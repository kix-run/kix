# 2026-10-01 · `kix/lib/eval/resolve.nix` · A missing-dependency error on an auto-instantiated instance does not say which instance caused it to be created.

`describeRequester` prints `immich/valkey (auto-instantiated): dependency 'valkeyPassword' was not found for namespace 'immich'`. The cluster file never mentions `immich/valkey`; the user has to work out that immich's required `valkey` dependency pulled it in from `availablePackages`. `eval/auto.nix` knows the demanding instance (`mkItem d ns requester`) but does not record it on the instance it creates, so the message cannot name it.
