+++
kind = "silent"
cli = ["--output"]
+++
A plugin no longer gets the `-o` format in the `KIX_OUTPUT` environment variable. When a user runs `kix -o json NAME ARGS...`, Kix now runs `kix-NAME --output json ARGS...`. A plugin that read `KIX_OUTPUT` must read `--output` from its arguments instead. A plugin that runs `$KIX_BIN` must pass `--output` on if it wants the same format.
