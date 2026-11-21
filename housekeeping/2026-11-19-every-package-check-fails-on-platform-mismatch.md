# 2026-11-19 · `every-package-evaluates` check · The check fails on this workstation with "platform mismatch" for the cilium Helm chart.

`nix build .#checks.x86_64-linux.every-package-evaluates` stops at `helm-chart-cilium-1.20.5.drv` with `Reason: platform mismatch`, then `helm-render-cilium.json` fails as its dependent. It fails the same way on an unchanged `origin/main` (1722cd7f), so a local run cannot confirm a package change. The message does not say which platform or feature the chart build asks for.
