# 2026-10-01 · `kix/packages/external-dns` · The package cannot run a webhook DNS provider.

A webhook provider (`--provider=webhook`) talks to a second container in the
same pod that implements the provider API. The package renders one container,
so `webhook` is left out of the `provider` enum: it would pass evaluation and
fail at runtime. Supporting it needs a typed sidecar container on the
Deployment, with its image, args, and port. See providers.nix.
