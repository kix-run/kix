+++
kind = "error"
library = ["kix.mergeGuarded", "kix.mergeEnv", "kix.guardArgs", "kix.storage.mkClasses"]
id = "K6417"
+++
`kix.mergeGuarded`, `kix.mergeEnv`, `kix.guardArgs`, and `kix.storage.mkClasses` take `scope` in place of `who`, and their errors now name the instance and its package as fields, so `kix check -o json` reports them. A package that passes `who` to one of them stops with an error. Replace `who = ...` with `inherit scope;`. `kix.mergeEnv` also takes `option`, the env option the error names (default `env`), and an `owned` group can give `reason` in place of `from` for a variable the package refuses outright. A `kix.mergeGuarded` refusal now tells you to remove the locked path from the option you set. Every error from `scope.fail` in a built-in package also names the package.
