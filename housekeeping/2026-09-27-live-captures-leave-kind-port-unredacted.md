# 2026-09-27 · `docs/nix/output-transforms.nix` · Live captures keep the random kind apiserver port in their drift views.

kind binds the apiserver to a random local port, and no drift transform
redacts `127.0.0.1:<port>`. `tutorials/02-hello-world/kubectl-cluster-info.json`
therefore drifts on every run, and so does
`how-to/application-health/health-verbose.json`, whose debug log now includes
`apiserver reachable endpoint="https://127.0.0.1:39119/"`.
