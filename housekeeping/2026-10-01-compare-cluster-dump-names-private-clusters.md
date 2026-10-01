# 2026-10-01 · `scripts/compare-cluster-dump.py` · The public diff script names a private cluster and a customer.

Comments and code refer to `nw1` (`nw1-diff-ignores.txt`, "nw1's k8s/") and to a customer's Valkey instance name, so the script fails the public hygiene grep (`rg -i 'nw1|shopfront' scripts`). The nw1-specific ignore file belongs with that cluster, and the comments need neutral examples before the repository is published.
