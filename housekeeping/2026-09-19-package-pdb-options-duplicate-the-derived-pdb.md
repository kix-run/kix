# 2026-09-19 · `kix/packages/external-dns` · The package still carries a `pdb` option and writes its own PodDisruptionBudget, which the spread plugin now derives for every multi-replica workload.

Since v2_discussions/143 landed, a PDB written by the package wins over the
derived one, so nothing breaks, but the option is a second place to get the
same answer and it fires on single-node clusters where the plugin would
correctly emit nothing. `kix/packages/external-dns/default.nix` (`pdb`
option, default `enabled = true`); `kix/packages/python-app/default.nix`
carries the same shape (`pdb` option, `self.pdb` part). coredns lost its
copy in the seal conversion. The `hasPDB` scorecard rule in
`kix/lib/rules/reliability.nix:157` is in the same position: it now only
fires where spread is off. Worth a sweep of `grep -rl PodDisruptionBudget
kix/packages/` to decide which hand-written PDBs still carry information the
derivation does not.
