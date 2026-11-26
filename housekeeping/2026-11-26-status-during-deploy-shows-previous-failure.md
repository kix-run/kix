# 2026-11-26 · `kix status` · While a deploy is running, `kix status` shows only the previous failed deploy.

Seen on EKS and GKE: after a failed deploy, a second deploy was in progress and `kix status` still reported `failed_deploy` for the old one, with no sign that a new deploy was running. A user watching from another terminal reads it as the new deploy having failed.
