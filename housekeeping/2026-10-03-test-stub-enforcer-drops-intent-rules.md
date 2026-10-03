# 2026-10-03 · `kix/lib/tests/default.nix` · The stub enforcer's `translateIntentRules` returns no rules, so unit tests cannot see a world egress port.

A package that builds a `kix.operandPolicy` from `netpol.translateIntentRules` (cnpg-cluster's `<instance>-backup-egress`, stackgres-cluster, velero) renders an empty `egress` list under `netpolOn`. The test `cnpg-cluster-backup-resources` can only check that the policy exists and whom it selects; the port derived from `backup.extraSpec.configuration.endpointURL` goes unchecked. A stub that echoes its intents would let tests assert the port.
