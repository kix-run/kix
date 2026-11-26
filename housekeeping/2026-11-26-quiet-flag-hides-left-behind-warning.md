# 2026-11-26 · `kix deploy -q` · The quiet flag hides the left-behind warning that the confirmation prompt depends on.

With `-q`, `kix deploy --prune` asks for confirmation without first printing which objects the prune will leave on the cluster. The user answers the prompt without the one fact it is about.
