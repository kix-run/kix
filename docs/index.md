# kixpkgs

Declarative Kubernetes manifests built with Nix.

kixpkgs replaces Helm charts and Ansible playbooks with plain Nix functions that produce Kubernetes resources. Every cluster is a reproducible, type-checked Nix evaluation — no YAML templating, no runtime surprises.

## Quick start

```bash
# Build a cluster's manifests
nix build .#cluster-example --extra-experimental-features pipe-operators

# Diff against a live cluster
./scripts/kix-dump.py --all cluster-dump/
./scripts/kix-diff.py ./result cluster-dump/
```

## Documentation

<div class="grid cards" markdown>

-   **Tutorials**

    ---

    Step-by-step guides to get started with kixpkgs from scratch.

    [:octicons-arrow-right-24: Start learning](tutorials/index.md)

-   **How-to Guides**

    ---

    Practical recipes for common tasks — migration, monitoring, testing.

    [:octicons-arrow-right-24: Find a guide](how-to/index.md)

-   **Reference**

    ---

    Technical descriptions of kixlib APIs, package contracts, and configuration.

    [:octicons-arrow-right-24: Browse reference](reference/index.md)

-   **Explanation**

    ---

    Background, design rationale, and architectural decisions.

    [:octicons-arrow-right-24: Understand why](explanation/index.md)

</div>
