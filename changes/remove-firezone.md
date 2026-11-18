+++
kind = "error"
packages = ["experimental/firezone"]
id = "K1728"
+++
The `firezone` package is removed, and a cluster that names `packages.experimental.firezone` or `packages.firezone` fails with `[K1728]`. The package ran the Firezone 0.7 server, which upstream stopped updating in 2023. Firezone 1.x does not support self-hosting its control plane, and its images have no version tags that a package could pin. Remove the Firezone instances from your cluster definition. To run the Firezone gateway, follow upstream's instructions. The package's source is in the Kix git history, under `kix/packages/experimental/firezone`.
