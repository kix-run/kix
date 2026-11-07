# 2026-11-06 · `cli/runtime/legal.py` · THIRD_PARTY_LICENSES omits the Go modules built into helm, kubectl, and sops.

The runtime ships the upstream helm, kubectl, and sops binaries. Each one
links hundreds of Go modules, many under MIT or BSD licences that ask for
their notice in every copy. THIRD_PARTY_LICENSES carries only each
project's own LICENSE file. `go version -m <binary>` lists the modules.
