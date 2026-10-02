# 2026-10-02 · `kix/packages/tailscale` · `out.mkRecorder` with S3 credentials works only from an instance in the operator's namespace.

The operator reads the S3 Secret from its own namespace. Without a public
`kix.isUntrackedRef`, the builder cannot tell a `kix.untrackedRef` name
(which may name a Secret there) from a Secret the caller built in its own
namespace, so it refuses both when the caller is elsewhere. A consumer in
another namespace has to add an instance in the operator's namespace to get
a recorder. A reference type that carries its namespace would lift this.
