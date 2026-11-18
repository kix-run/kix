# Loki logs an error "empty ring" on every start

On each start of a single-pod Loki, its log has one `level=error` line from
`ratestore.go:110`: `error getting ingester clients err="empty ring"`. It
appeared on the 3.7.10 start and on the 3.7.8 start after a rollback, in
the same test cluster. The pod still reports ready and serves queries, so
the line looks harmless, but an operator scanning for errors will see it
at every restart.

The package sets `common.ring.kvstore` to in-memory. The line may come
from the rate store asking for ingester clients before the in-memory ring
has a member, but this is a guess and I did not check it. Found while
bumping `experimental/loki` from 3.7.8 to 3.7.10.
