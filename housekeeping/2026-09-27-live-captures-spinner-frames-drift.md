# 2026-09-27 · `docs/nix/output-transforms.nix` · Spinner frames make live capture drift views nondeterministic.

`nix run ./docs#regen-captures -- --group how-to/application-diff --check`
reported drift in `diff-clean.json` although the command output had not
changed. In one run, the drift view held `Fetched 16 resources across 60
resource types` as its own line. In the other, the same text followed a
spinner frame: `⠉ Fetching live cluster state... Fetched 16 resources ...`.
Whether a spinner tick lands before the next message depends on timing, and
`normalize-tty-output` does not remove spinner frames, so `--check` can fail
on any live capture that shows kix's progress spinner.
