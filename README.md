# Kix

Kix is a Kubernetes compiler. You define packages and clusters in Nix, check the whole cluster locally before touching Kubernetes, preview changes against the live cluster, and deploy in dependency order.

The output is standard Kubernetes manifests. When one resource references another, Kix records the dependency and uses that graph to order deploys, generate network policies when enabled, run policy checks, and show what a change affects.

Here is a minimal `cluster.nix` that runs one package on a local `kind` cluster:

```nix
{ kix, packages }:

kix.buildCluster {
  modules = [
    kix.flavors.kind

    {
      namespaces = {
        tutorial-04 = { };
      };

      instances.tutorial-04 = {
        hello-world = {
          package = packages.echo-server;
          config = {
            message = "Hello from my first Kix cluster!";
          };
        };
      };
    }
  ];
}
```

## Install

Install Kix on Linux (`x86_64-linux`, `aarch64-linux`) or Apple silicon macOS (`aarch64-darwin`):

```sh
curl -fsSL https://kix.run/install | sh
```

The script verifies the release archive, unpacks Kix and the Kix runtime (Nix, Helm, `kubectl`, and `sops`) into `~/.local/share/kix/<version>/`, and links `~/.local/bin/kix`. It does not edit your shell startup files. Run `kix doctor` to check the installation.

To try Kix on a local `kind` cluster with [kix-examples](https://github.com/kix-run/kix-examples), start with the [tutorials](https://kix.run/docs/tutorials/). To install from a release archive directly or see how projects pin their version of Kix, read [Install and run Kix](https://kix.run/docs/how-to/start-and-inspect/install-and-run-the-kix-cli/).

### Build and run from source

To run `kix` from [`cli/`](cli/) with Cargo, enter the Nix development shell so `KIX_RUNTIME_DIR` points at the Kix runtime and `CARGO_TARGET_DIR` stays outside the checkout:

```sh
nix develop
cargo run --manifest-path cli/Cargo.toml --bin kix -- check example-hello
```

You can also build and run the packaged binary directly with Nix:

```sh
nix run .#kix -- check example-hello
```

If you already installed a release archive and want to run a Cargo build without Nix on `PATH`, set `KIX_RUNTIME_DIR` to `~/.local/share/kix/<version>/libexec/kix` and set `CARGO_TARGET_DIR` outside the repository checkout.

## Documentation

Full documentation is at [kix.run/docs](https://kix.run/docs/):

- [Tutorials](https://kix.run/docs/tutorials/): step-by-step lessons that build a working local cluster one concept at a time.
- [How-to guides](https://kix.run/docs/how-to/): task guides for operating clusters, writing packages, wiring dependencies, adopting existing resources, and running Kix in CI.
- [Reference](https://kix.run/docs/reference/): cluster and package options, resource helpers, built-in packages, policy rules, and `kix` commands.
- [Explanation](https://kix.run/docs/explanation/): how the dependency graph, packages and contracts, generated network policies, Helm charts, availability levels, policy rules, and Server-Side Apply fit together.

## Status

Kix is below 1.0 and uses semantic versioning. Minor releases may include breaking changes, listed with upgrade steps in [CHANGELOG.md](CHANGELOG.md). Patch releases do not break stable packages in [`kix/packages/stable/`](kix/packages/stable/), while experimental packages in [`kix/packages/experimental/`](kix/packages/experimental/) may change in any release. Each project pins its version of Kix in `flake.lock`, and Kix runs that version automatically.

## Repository

- [`cli/`](cli/): Rust source for Kix and the in-cluster Kix operator
- [`kix/lib/`](kix/lib/): the Kix library
- [`kix/packages/`](kix/packages/): `stable/` and `experimental/` package definitions
- [`docs/`](docs/): documentation site

Kix is developed largely by AI coding agents, directed and reviewed by its two maintainers. [`discussions/`](discussions/) holds design documents, and [`housekeeping/`](housekeeping/) tracks known problems to fix later.

## Feedback and bugs

Ask questions and share feedback in [GitHub Discussions](https://github.com/kix-run/kix/discussions). Report bugs in [GitHub Issues](https://github.com/kix-run/kix/issues).

## License

Apache License 2.0. See [LICENSE](LICENSE).
