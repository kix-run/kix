+++
kind = "error"
library = ["kix.guardArgs", "kix.mergeArgs"]
id = "K5396"
+++
If your cluster uses only built-in packages, no changes are needed. If you maintain custom packages, replace calls to `kix.guardArgs` with `kix.mergeArgs`; calling `kix.guardArgs` now stops the build with `[K5396]`. `kix.mergeArgs` returns the full argument list (or flag attribute set), so pass the package's own flags in `args` and assign the result directly instead of combining it with `++` or `//`. Set the required `parser` argument to `"gnu"`, `"component-base"`, `"go"`, `"go-arg"`, or `"paerser"`. In `args`, pass plain strings for unlocked flags, `{ defaults = [ "--flag=value" ]; }` for defaults that `extraArgs` replaces, and `{ flags ? [ "--flag=value" ]; names ? [ ]; families ? [ ]; reason = "..."; fix ? "..."; }` (or `from` instead of `reason`) for flags the package reserves. Leave the fix out of `reason`: Kix tells users to remove the flag from `extraArgs` by default, or prints `fix` when set.
