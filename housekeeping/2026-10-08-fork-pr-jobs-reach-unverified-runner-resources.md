# 2026-10-08 · `.github/workflows/` · Nobody has checked what a fork PR's job can reach from a Spindle VM.

`cli-tests.yml` and `bundle-checks.yml` run on `pull_request` on self-hosted Spindle VMs, so a fork's PR runs its own code there. A security review could not verify whether that code can reach the GCE metadata server (and the VM's service account token) or the Lithus read-through Nix cache. If it can, any outside contributor's PR can use them.
