# 2026-10-17 · `docs-legacy/` · The docs show an optional dependency setting a pod env var, which package-review calls a defect.

`HANDBOOK.md:349` and `BEST-PRACTICES.md:574-579` set `ML_URL` from `machineLearning != null`. package-review W17 and D16 say an optional dependency must not change the pod template of a disruptive workload. Authors copying the docs example write the defect.
