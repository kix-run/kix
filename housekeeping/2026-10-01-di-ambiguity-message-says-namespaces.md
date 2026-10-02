# 2026-10-01 · `kix/lib/eval/resolve.nix` · The ambiguous-dependency message says "multiple namespaces" when the candidates share one, and names none of them.

`resolveArg` throws `dependency '<arg>' matches instances in multiple
namespaces` whenever more than one candidate sits outside the requester's
namespace, including when all of them are in the same other namespace. Two
`cluster-issuer` instances in `cert-manager` that both answer `clusterIssuer`
give every `kix.expose` consumer in `apps` this message. It lists neither the
candidates nor their namespaces, so the user has to search the cluster file
for every instance of the alias before setting `deps.<arg>`.
