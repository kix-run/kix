# 2026-09-27 · `cli/kix-cli/src/cli.rs` · `kix inspect --help` promises deps, parts and `out`, but the command lists rendered resources only.

The help line reads "Deep-dive: DI deps, parts, out". `commands/inspect.rs` prints resource counts by namespace and kind and nothing about instances. The how-to "Inspect an instance's deps, parts, and `out`" falls back to raw `nix eval` for the parts it names. `kix diff --help` has the same kind of gap: "Colored diff against live cluster" does not mention `--from`.
