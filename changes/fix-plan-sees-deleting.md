+++
kind = "fixed"
+++
`kix plan`, `kix deploy`, and `kix rollback` now notice an object the build
leaves unchanged that is missing from the cluster or being deleted, and apply
it again. Before, only `--reconcile` or a change to the object did this, so
an object someone deleted stayed missing, and an object being deleted
disappeared after a deploy that reported success. The plan lists each kind in
the build once to find these objects, so it needs permission to list those
kinds. For a kind it may not list, it prints a warning and leaves the
unchanged objects of that kind as they are. `--offline` plans still read
nothing from the cluster. The Kix operator already recreated such objects.
