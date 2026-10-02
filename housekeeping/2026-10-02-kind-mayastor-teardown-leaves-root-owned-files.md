# 2026-10-02 · `scripts/kind-mayastor.sh` · After `teardown`, a plain `rm -rf` of `$KIX_MAYASTOR_HOST_DIR` fails on root-owned files.

io-engine runs privileged and creates `io-engine/ptpl/pool` and
`io-engine/ptpl/nexus` as root under each worker's directory, so the pool
directory needs `sudo rm -rf`. Neither the script header nor `teardown` says
so, and the mayastor plan's teardown step uses plain `rm -rf`.
