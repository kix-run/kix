+++
kind = "added"
+++
`kix deploy`, `kix rollback`, and the in-cluster operator now refuse to deploy a cluster that a newer minor of Kix deployed last, and apply nothing. The message names both versions and the commit of the last deploy, and says to make the change on a commit that uses the newer Kix or to move the project to it with `kix upgrade`. The operator marks the queued Activation `Failed` and emits an `OlderKix` event. `kix plan`, `kix plan --read-only`, and `kix deploy --dry-run` print the same facts as a warning. To move a cluster back to an older Kix on purpose, for example to leave a bad release, set `KIX_ALLOW_DOWNGRADE` to the version that deployed it last. The Activation record then gets the annotation `kix.run/downgraded-from`.
