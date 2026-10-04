# kix.untrackedRef cannot name an object in another namespace

`kix.untrackedRef { kind; name; by; }` records `apiVersion|kind|name` in the
referring manifest's `kix.run/expects` annotation. `kix deploy`
(`wait_for_expectations` in `cli/kix/src/cluster/readiness.rs`) looks the
object up in the referring manifest's namespace. A reference to a Secret in
another namespace therefore waits for a Secret that is never there, and a
cluster-scoped referrer fails at once with "the referring manifest has no
namespace".

Found on kind: openbao's `out.externalSecretsProvider` put the marker for
its CA Secret in a ClusterSecretStore's `caProvider`, and the deploy of
`clusters/test-openbao.nix` stopped there. The package now passes the
Certificate's `out.name` instead, which orders the reader after the
Certificate is Ready.

Fix: let `untrackedRef` take `namespace`, carry it as a fourth field in the
annotation, and look it up there. Until then, a reference that crosses
namespaces uses the creating resource's `out` value instead of the marker.
