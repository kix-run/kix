# 2026-10-03 · `kix/packages/volsync` · `out.mkReplicationSource` takes the S3 keys in the restic repository Secret, outside the `storageCredentials` contract, and cannot check that RESTIC_REPOSITORY names the store.

VolSync's restic mover reads RESTIC_REPOSITORY, RESTIC_PASSWORD, and the AWS keys from the one Secret `spec.restic.repository` names (`internal/controller/mover/restic/mover.go`), and Kix cannot compose a Secret from another Secret's values. So a cluster copies the store's keys into a second Secret and types the store URL by hand (`clusters/test-volsync.nix` builds it from `config.clusterDomain`). A wrong URL passes evaluation, and the network policy derived from `endpointService` then opens a path the mover never uses.

Decision required from Adam: accept the duplicated Secret, or add a way to build one Secret from another's keys (a Kix-run Job, or an External Secrets template once that package lands).
