# 2026-11-14 · `kix deploy` · The server-side dry run does not catch a Service whose fixed clusterIP is already taken, so the deploy fails partway.

Found testing on kind: `example` asks for CoreDNS at 10.96.0.10, which kind's
`kube-dns` Service holds. The dry run passed, and the apply failed with
"failed to allocate IP 10.96.0.10: provided IP is already allocated": 81
objects created, 1 failed, 41 not sent, record Failed. The apiserver does not
allocate IPs in a dry run, so this is its limit. A preview could list
Services with a fixed `clusterIP` and check that no other Service holds it.
