# 2026-10-02 · `docs/nix/captures-offline.nix`, `docs/nix/captures-live.nix` · `--help` runs the backticked words in its usage text as commands.

The usage heredoc is unquoted (`cat <<USAGE`), so the shell expands `` `offline` `` and `` `live` `` as command substitutions. `nix run ./docs#regen-captures-offline -- --help` prints "line 23: offline: command not found" and the first line reads "capture every  step in". Quoting the delimiter (`<<'USAGE'`) keeps the text literal.
