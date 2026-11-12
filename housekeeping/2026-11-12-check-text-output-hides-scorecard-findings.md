# 2026-11-12 · `cli/kix-cli/src/commands/check.rs` · `kix check` prints how many scorecard warnings a cluster has and no way to read them.

The text and JSON output give only "0 errors, 41 warnings, 14 info" for kix-examples `homelab-kind`. `-v` adds log lines but no findings. Only `--sarif` lists them, which the command's help does not suggest for reading.
