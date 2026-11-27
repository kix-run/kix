# 2026-11-27 · `cli/kix-cli/tests/kind_integration_test.rs` · Two kind test fixtures define a ConfigMap that nothing references, so every run prints a library warning.

`SHARED_ROLE_NIX` and `DRIFT_NIX` each build a ConfigMap that no root references, and the Kix library warns "ConfigMap/... is not referenced by root" on every command. The warning names the object, so an assertion that the plan does not mention it failed on the warning alone. Referencing the ConfigMap from a root, or asserting on the plan's own object line, keeps the tests from matching library warnings.
