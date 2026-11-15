# 2026-11-15 · `kix/lib/tests/` · Most negative library tests pass on any thrown error, and Nix gives a test no way to check which one.

`evalFails` (`kix/lib/tests/default.nix`) is true when building the cluster throws. About 730 calls use it. A test that expects `[K0001] replicas was removed` also passes if the cluster fails for an unrelated reason, such as a typo in the fixture that trips a different Kix check. Missing attributes and type errors are not caught by `builtins.tryEval`, so those abort the run instead of passing, but any `throw` or `assert` passes.

`builtins.tryEval` returns only `success`, never the message, so no helper inside a Nix evaluation can read the error id or text. A cluster's failed package assertions are data before Kix raises them, and a helper could read those. On 2026-11-15 I measured which kind of failure each `evalFails` call sees in 12 of the unit files with the most calls: of 237 calls that see a failure, 11 fail on an assertion and 226 on a throw from `scope.fail`, `kix.fail`, or a library check. An assertion-only helper would cover about 3 percent, so I did not add one.

`kix/lib/tests/caught.nix` reads the text of a refusal by loading files through `builtins.scopedImport` with `throw` bound to return `{ thrown = <message>; }`. That works when a test reads the value at the place the refusal returns it, as `units/log-agents.nix` does with a package's settings. It does not work for a whole cluster built with `loadCaught ../../eval`, for two reasons I checked on 2026-11-15:

- A refusal inside a check that the code forces with `builtins.seq` (most of them: `withChecks` in `scope/builders.nix`, the validators, `_refTargetsCheck` and `assertionCheck` in `eval/cluster.nix`) returns its record, and `seq` discards it. A package that builds a CronJob with `scope.mkResource` fails to build normally, but the caught cluster builds, renders the CronJob, and holds no trace of the refusal.
- A refusal in a value position returns a record where the evaluator expects a resource, a string, or a list. The next use fails with an error `tryEval` cannot catch. `root = scope.fail { ... }` stops with `attribute 'out' missing` in `core/activation.nix`, and the `cnpg` test with `image.tag = "latest"` stops with a stack overflow. Either one aborts the whole test run.

Nix has no way to keep a refusal both as a value and as a stop, so `caught` stays a tool for reading one message at a known place.

Options:

1. A runner outside Nix. Each negative case becomes data, `{ expect = "K0001" or "message text"; cluster = mkCluster [ ... ]; }`, collected next to the tests. A script evaluates each case with its own `nix eval`, expects it to fail, and checks stderr for `expect`. About 1.5 seconds a case, so 730 cases take two to three minutes run eight at a time in CI. Moving each existing call into a case is manual work, because most calls sit inside `&&` chains with their control cases.
2. The same runner for new tests only, with `evalFails` kept for old ones. Cheap to start, and the old tests stay weak.
3. Leave it. Many negative tests already sit next to a passing control case that differs only in the setting under test, which limits how far an unrelated failure can hide.

Option 1, started with option 2, is the one that makes the tests check what they claim. The owner decides.
