# Roadmap

## Internals

- [x] proper module system for config
- [x] no "defaults"
- [x] global config object that is passed around
- [x] fragments for separating concerns and teams
- [ ] v2_discussions/11 -> injecting storage and other infra items like certs from the cluster graph => different package types?
- [ ] post-eval validation 
- [ ] secret handling and injection (agenix, etc) => hashes of encrypted secrets are beautiful (dont trigger change) + injection can happen in kix-deploy
- [ ] autogenerating, checking, verifying, and abstracting network policies (cilium compatible)
- [ ] migrations as k8s jobs to be defined for major version upgrades or similar (per package?)
- [ ] use "already existing" cluster elements, like "this secret already exists in the cluster" -> kix deploy will complain
- [ ] auto-inject dependencies (valkey @ immich) => keep the "ease of use" alive
- [ ] deep check package level dependencies, if the package root crd is pulled in properly

## Open design questions

- [ ] package root as common leaf  dependency or root

## Case Studies

- [ ] immich

## Warnings, Errors, Checks

- [x] misuse of requires
- [x] missing resources in graph
- [ ] run static analysis of kyverno, etc
- [ ] checks on packages (incompatible k8s version, incompatible with prometheus < 4.5.23, etc
- [ ] sanity checks on namespace resource quotas and similar

## DSL - how to make building in kix nicer

- [ ] auto-selectors based on store path (instead of labels) -> auto-wires services
- [ ] RBAC and its verbs, prior work exists in some doc somewhere
                                                              w
## kix deploy

- [ ] wait for ready across all resource types
- [ ] non k8s jobs (e.g. forejo user creation) => start with execution on "ssh", lateron can be crossplane or a forejo provider plugin
- [ ] auto-collect readyness & custom general runtime readyness (also outside k8s)
- [ ] auto-inject package identity label? At least put associated package name and version like helm has best practice


## kix diff

- [ ] on instance level
- [ ] on resource level
- [ ] warnings and checks if PVCs change or major versions change => hint this on the package definition (is a major version change roll-backable - or only for one version like postgres)
- [ ] potentially even warning with live-cluster hints (sanity checks on resource limits etc)

## kix cli

- [ ] working without installed nix

## Future work

- [ ] AI Skills: recommended in-kix actions on warnings or errors; skill to read changelog and derive warnings and checks...
- [ ] Multi-zone, multi-cluster management
    > However the orchestration of "oh this region is down, let me then adjust myself" is a runtime concern. We can also model this through a reeval (global variables based on global cluster state)
- [ ] LSP or checks for code smells
- [ ] feature parity with helm, argo, flux
- [ ] - running jobs - how does an enduser run something "once" or over and over again - instead of registering a service (not a big problem for now though)
- [ ] rust bridge to nix binary in cli (https://github.com/nixops4/nix-bindings-rust)
- [ ] permission system in kix deploy (what blast radius am i allowed to have)
- [ ] kix operator

## Other

- [ ] create skill/guide for proper package creation
- [ ] how-to case studies for simple cases
- [ ] naming conventions for packages, services, resources, etc
- [ ] naming of the project and internals
