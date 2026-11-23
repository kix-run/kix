+++
kind = "error"
library = ["kix.mergeGuarded", "kix.mergeEnv", "kix.guardArgs", "kix.storage.mkClasses"]
id = "K6417"
+++
In custom packages that call `kix.mergeGuarded`, `kix.mergeEnv`, `kix.guardArgs`, or `kix.storage.mkClasses`, remove `who` and pass `inherit scope;`. Passing `who` now stops evaluation with an error. Cluster definitions that use only built-in packages need no changes. These helpers now raise errors through `scope.fail`, and `scope.fail` now records `package` on built-in packages as well as `instance`, so `kix check -o json` includes both fields. `kix.mergeGuarded` also accepts an optional `object` attribute set and now tells users to remove locked fields from the option they set. `kix.mergeEnv` accepts `option` (default `"env"`) to name the option in errors, and its `owned` entries accept `reason` instead of `from` when a package rejects an environment variable outright.
