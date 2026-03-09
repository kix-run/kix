# Dependency Tracking V4: Architecture Redesign

Supersedes V1 (typed refs), V2 (structural inference), V3 (tradeoff analysis).
Incorporates Luca's feedback on tight coupling, inversion of control, and
nested evaluation.

## Context

Luca's feedback on V3 identified several problems with the current architecture:

1. **Tight coupling**: monitoring assumes `coredns-deployment` is a known field.
   This defeats the purpose of kix making any abstractions useful.

2. **Wrong dependency direction**: Instead of "what are the labels of the thing
   I have to find", charts should ask "what are the labels I need to put to BE
   found." The second is MUCH nicer with the module system.

3. **Manifests as config**: Higher-level modules should have NOTHING to do with
   lower-level manifests. The manifests should be *derived* from the config,
   not *be* the config.

4. **Nested evaluation**: Module systems can be evaluated multiple times. Each
   chart could have its own module system where the manifest IS the derivation
   AND the config. A higher-level module system (like values.yaml) interacts at
   a higher level of abstraction.

5. **The brain-breaker**: How do you do `corednsDeployment |> withAutoscaler`
   when that needs to touch the lower-level eval loop?

Five expert agents researched these problems in parallel. This directory
contains one file per finding.

## Files

- `01-manifests-from-config.md` — Manifests derived FROM config, not BE the config
- `02-underscore-fields.md` — The `_type` pattern and extensibility for metadata
- `03-inversion-of-control.md` — The "BE found" pattern and capability interfaces
- `04-with-autoscaler.md` — Solving the `|> withAutoscaler` brain-breaker
- `05-nested-eval.md` — Nested evalModules and the pragmatic path
- `06-ecosystem-validation.md` — How Helm/Argo/Crossplane/cdk8s/Pulumi validate these ideas
- `07-proposed-architecture.md` — The layered architecture that emerges (SUPERSEDED by 07A)
- `07A-proposed-architecture.md` — **Revised architecture incorporating all feedback and decisions**
- `08-questions-for-luca.md` — Open questions and decisions needed
- `09-nix-development.md` — Recent Nix development (2.24–2.33), relevant PRs, RFCs
- `10-lucas-feedback.md` — Luca's feedback on V4, decisions, and external references (RFC 189, selfhostblocks, Modular Services)
