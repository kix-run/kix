# 2026-11-14 · `kix history` · Marks every earlier deploy "[build not on this machine]", even builds made here minutes before.

Found testing 0.10.0-rc.4 on kind. The label checks a store path such as
`/nix/store/...-kix-activation-example.json`, which the default `kix` builder
never writes, so the check always fails. Rollback to those deploys works
anyway. The label should check what rollback actually needs, or be removed.
