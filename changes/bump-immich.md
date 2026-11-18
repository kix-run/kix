+++
kind = "silent"
packages = ["experimental/immich", "experimental/immich-machine-learning"]
touches-data = true
+++
`immich` and `immich-machine-learning` now run Immich 3.4.1 (was 3.3.5). Immich 3.4.0 fixes the security advisories it published on 2026-11-10, among them GHSA-7j23-rprg-3g5q, a takeover of any account through a forged OAuth `state` cookie, and GHSA-wp5v-5wj6-j2fh, a file read through symbolic links in an external library. The server's API no longer accepts a `password` field in `PUT` or `PATCH /api/users/me`. A script that changes a password that way must call `POST /api/auth/change-password` instead. The first deploy stops the server, which then adds three database migrations when it starts. Immich does not support going back: an Immich 3.3.5 server stops at start on the migrated database. Back up the database before you deploy if you may need to go back, and restore that backup to go back. The machine-learning worker keeps its default model revision, so smart search and face data stay valid.
