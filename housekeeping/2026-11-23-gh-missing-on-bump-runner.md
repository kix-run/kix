# 2026-11-23 · `bump` runner · `gh` is not on the runner's PATH, though the repo guidance tells agents to use it.

On the bump job, `gh api` fails with "command not found", so the release metadata has to come from `curl` against `api.github.com`, which can return 504 on a busy request. Either install `gh` on the runner or have the bump instructions name `curl` as the fallback.
