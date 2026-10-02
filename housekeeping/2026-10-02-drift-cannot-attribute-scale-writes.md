# 2026-10-02 · `cli/kix/src/cluster/drift.rs` · `kix drift` reports a scaled Deployment as drifted with no owner, because Kubernetes 1.36 records no managedFields entry for a `/scale` write.

On kind v1.36.1 (kubectl 1.37.1), `kubectl scale` and `kubectl patch
--subresource=scale --field-manager=probe` both change `spec.replicas` and take
it out of kix's `Apply` fieldset, but add no managedFields entry of their own.
`kix drift` then prints `Deployment/reloader@reloader DRIFTED: fields managed
by Kix have changed; Kubernetes has not recorded another tool as their owner`,
even after scaling back to the deployed value. `foreign_owners` and its doc
comment assume `/scale` writes show up as a manager with subresource `scale`,
and `cli/README.md` says the same; neither holds on this server version. Seen
in the W6 K11 reloader kind run (scoped variant, scale to 0 and back to 2).
