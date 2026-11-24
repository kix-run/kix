+++
kind = "error"
library = ["kix.guardArgs", "kix.mergeArgs"]
id = "K5396"
+++
If your cluster uses only built-in packages, no changes are needed. If you maintain custom packages, replace calls to `kix.guardArgs` with `kix.mergeArgs`; calling `kix.guardArgs` now fails evaluation with `[K5396]`. Unlike `kix.guardArgs`, `kix.mergeArgs` returns the full argument list (or attribute set), so pass the package's own arguments in `args` and assign the result directly to the container's `args` instead of concatenating lists. Set `parser` (now required) to `"gnu"`, `"go"`, `"go-arg"`, or `"paerser"`. In `args` (and `after`, for arguments placed after `extraArgs`), pass plain strings for unlocked flags, `{ defaults = [ "--flag=value" ]; }` for defaults that `extraArgs` may override, and `{ flags ? [ "--flag=value" ]; names ? [ ]; families ? [ ]; reason = "..."; fix ? "..."; }` (or `from` instead of `reason`) for flags the package owns or blocks. Omit the remedy from `reason`; Kix tells users to remove the flag by default, or prints `fix` when set.
