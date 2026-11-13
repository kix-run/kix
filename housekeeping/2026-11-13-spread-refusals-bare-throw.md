# 2026-11-13 · `kix/lib/eval/auto.nix` · The refusal for a once-per-cluster package in several namespaces is still a bare `throw`.

`spreadRefusals` joins its messages into one `throw`, so Kix shows it as plain Nix output with "stack frames hidden" and `kix check -o json` has no fields for it. Its sibling `besideConsumerRefusals` goes through the problem list with an id and a fix. The two should look the same.
