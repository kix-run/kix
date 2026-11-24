# 2026-11-24 · `kix/lib/core/resource.nix` · Errors about a `scope.mkCRDRef` or `mkImport crds` handle name the instance in the message text instead of in the record's `instance` field.

`mkCRDRefHandle` (around line 1294) builds `who = "<site> <group>/<kind> in <ns>/<instance>"` and calls plain `fail`. `kix check -o json` then gives these errors no `instance` or `package` field, unlike the errors of `scope.fail` and the contract helpers. The function receives `instanceName` and `namespaceName`, but no `fail` from its caller.
