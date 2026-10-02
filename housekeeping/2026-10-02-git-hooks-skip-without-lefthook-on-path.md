# 2026-10-02 · `lefthook.yml` · A commit made where `lefthook` is not on PATH runs no hook at all.

The git hooks only call `lefthook`. In a shell outside devenv each one
prints "Can't find lefthook in PATH" and the commit succeeds, so nixfmt,
deadnix, and the commit-msg check that refuses `Co-Authored-By` trailers
never run. Agent sessions commit from such shells. Hit 2026-10-02
committing rework/w8-platform-cilium; nixfmt and deadnix were then run by
hand.
