# 164a: Versioning reviews, the record

**Status:** Reference
**Related:** `164_versioning_at_agent_speed.md`

Eleven reviews ran on 10 November 2026, each by a separate agent with a
neutral brief. None edited code. Each was asked to research online and to mark
claims taken from a search summary rather than a page it read; those are marked
(S) here. The links are as the reviews gave them and were not re-checked.

## Round 1: general reviews

**Review A, no constraints.** Keep one repository, one version, and the
same-minor rule. Cadence is the problem: five minors in seven days, with no
release branches, so each minor ends fixes for the one before. It suggested
batching breaking changes, release branches for fixes, a `-dev` version on
main between releases, and installing a newer patch when `flake.lock` runs
ahead of the runner. Of 16 recent commits touching the library or packages, 12
crossed a boundary.

**Review B, told the pace must stay.** Keep one version. Make deprecation the
default: the old name warns in a patch and is removed in a minor at least 14
days later. Count guarantees in days, after Kubernetes' "N months or N
releases, whichever is longer". Build tools before more version numbers: an
upgrade report filtered to the packages a project uses, a manifest diff across
the upgrade, and a CI check that fails a break with no changelog entry. 164
dropped the deprecation period at the maintainer's request and kept the rest.

## Round 2: schools

**Stability-first.** Keep the rule. Add a baseline every two to four weeks
with fix-only patches, and widen the state rule to reach back to the previous
baseline. `kix upgrade` is "Kubernetes' no-skipping rule with Rust's migration
step". Sources: [semver](https://semver.org/),
[PostgreSQL versioning](https://www.postgresql.org/support/versioning/),
[Kubernetes deprecation policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/),
[Rust editions](https://doc.rust-lang.org/edition-guide/editions/index.html),
[Go 1 compatibility](https://go.dev/doc/go1compat).

**Release channels.** Today's releases become "edge", and one minor in four
weeks is named "stable". The model works only with a stepping upgrade, because
a user who skips twenty minors loses the errors that name each fix. Start the
stable line only when an outside user asks. Sources:
[Rust nightly](https://doc.rust-lang.org/book/appendix-07-nightly-rust.html),
[DebianTesting](https://wiki.debian.org/DebianTesting),
[NixOS upgrading](https://nixos.org/manual/nixos/stable/#sec-upgrading),
[Kubernetes version skew](https://kubernetes.io/releases/version-skew-policy/),
[Node releases](https://nodejs.org/en/about/previous-releases),
[Firefox ESR](https://whattrainisitnow.com/release/?version=esr).

**Migrations as code.** Whether a release breaks something depends on the project.
Ship one machine-readable change record per break, let the agent make the edit,
and let Kix verify it: a rename must give an empty manifest diff, which an
agent cannot fake. Do not build a codemod engine, because structured Nix
editing is immature. Sources:
[Angular update spec](https://github.com/angular/angular-cli/blob/master/docs/specifications/update.md),
[OpenRewrite recipes](https://docs.openrewrite.org/concepts-and-explanations/recipes),
[Sui agent prompt](https://cdn.jsdelivr.net/npm/@mysten/sui@2.13.0/docs/migrations/sui-2.0/agent-prompt.md),
[agent migration study](https://arxiv.org/html/2510.26699v3) (only 2 of 10
repositories passed all tests; one agent hid 18 failing tests),
[Nima](https://discourse.nixos.org/t/announcing-nix-manipulator-nima-structured-edits-for-nix-that-keep-formatting/68513).

**Continuous delivery.** Every merge as a date-named release, pinned by
commit, with a bisecting `kix upgrade` and a pre-merge check over real
projects. It concluded that change records, that check, and bisecting are the
valuable parts under any numbering, and that dropping numbers hurts users
without agents most. Sources:
[Software Engineering at Google, ch. 21](https://abseil.io/resources/swe-book/html/ch21.html),
[minimal version selection](https://research.swtch.com/vgo-mvs),
[Stripe API versioning](https://stripe.com/blog/api-versioning),
[AI migrations at Google](https://research.google/blog/accelerating-code-migrations-with-ai/),
[Renovate automerge](https://docs.renovatebot.com/key-concepts/automerge/),
tj-actions compromise (S).

**Red team.** Stepping is sound for building and unsafe as first designed:
"nothing deploys until the end" contradicted the state rule; nothing could
withdraw a release; two-phase changes need required stops; the changelog
cannot be filtered. Agents make errors cheap to fix, not silent changes,
judgement calls, or review. Sources:
[Terraform state and newer providers](https://discuss.hashicorp.com/t/resource-instance-managed-by-newer-provider-version/61873),
[Helm and removed APIs](https://helm.sh/docs/topics/kubernetes_apis),
[Terraform AWS 4.0 objection](https://github.com/hashicorp/terraform-provider-aws/issues/23106),
[cooldowns](https://nesbitt.io/2026/03/04/package-managers-need-to-cool-down.html).

## Round 3: kinds of user

**Homelab user, no agents.** Needs a preview before starting, one combined
diff, pruning while stepping, a default target that has aged a week, a notice
when running a withdrawn release, a deploy that blocks on silent changes to
stored data, named errors for removed flags, and a no-upgrade workaround on
each advisory. No upgrade how-to page exists today. Sources:
[Nextcloud skipped major](https://community.start9.com/t/nextcloud-stuck-needing-db-upgrade-after-30-32-skipped-31/5341),
[Immich upgrading](https://docs.immich.app/install/upgrading),
[k3s upgrades](https://docs.k3s.io/upgrades/manual),
[Home Manager upgrading](https://nix-community.github.io/home-manager/usage/upgrading.html).

**Regulated platform team.** Security fixes during a freeze are where the plan
fails. Also needs a release mirror for CI without internet, one evidence file
per upgrade for the change ticket, and CVE ids on records. Each required stop
is a production ticket per cluster. Proposed a baseline every six weeks with
security-only patches, and to defer the backport promise until a regulated
user exists. Sources:
[Terraform AWS 4.0 S3 change](https://www.infoq.com/news/2022/02/terraform-aws-provider-s3),
[cost of Kubernetes release support](https://platformengineering.org/blog/the-true-cost-of-kubernetes-release-support-for-platform-engineers),
DORA RTS 2024/1774 Art. 17 (S), Argo CD release cadence (S).

**Agency with many client clusters.** Read the Lithus monorepo. One
`kix.toml` and one library input serve every cluster, so clients move together.
The monorepo already keeps one input per RKE2 patch and per NixOS release for
exactly this reason. Asked for per-cluster versions, `kix upgrade --cluster`,
grouped diffs, `kix.version` for shared modules, a deploy-time reminder of
silent changes, and a report of clusters deployed with a withdrawn release.
Sources:
[Terraform 0.13 upgrade guide](https://developer.hashicorp.com/terraform/language/v1.1.x/upgrade-guides/0-13),
[upgrading many configurations](https://discuss.hashicorp.com/t/strategy-for-upgrading-terraform/45203).

**Outside package author.** Package sets outside the repository get almost
nothing: no declared Kix range, change records filtered by catalogue package,
and a consumer's failure surfaces inside code they do not own. Asked for
records tagged with library symbols, a declared range per package set, and
library breaks on one day a week. Agreed none of it matters until private
catalogues exist (`ROADMAP.md`). Sources:
[Ansible collection requirements](https://docs.ansible.com/ansible/latest/community/collection_contributors/collection_requirements.html),
[Backstage versioning](https://backstage.io/docs/overview/versioning-policy),
[Helm library chart clash](https://github.com/cvat-ai/cvat/issues/7449),
[Stylix version check](https://discourse.nixos.org/t/stylix-and-nixpkgs-version-mismatch/64416).

**Maintainer.** About 100 commits touched `CHANGELOG.md` in a week, all under
one heading, so records need one file per change. Work out the kind with a check
on each pull request, while the agent that made the change is still there. The only judgement call is "silent break or bug fix". Withdrawing
must be one command that only edits the index, since release work already
happens around midnight. Drop the separate release gate and the upgrade bot for
now. Sources: GitLab changelog conflicts (S), towncrier (S), cargo yank (S).

**Unattended upgrade agent.** Needs stable error ids (today it matches wording
the Argon copy pass may change), change records as signed data with closed
fields (prose instructions are a prompt-injection path), Kix splitting each
diff into explained and unexplained, exit codes that say "needs a person", and
a progress file to resume from. Sources:
[next upgrade --agent](https://nextjs.org/docs/app/guides/upgrading/agent-upgrade),
[MCP TypeScript SDK v2 migration](https://ts.sdk.modelcontextprotocol.io/v2/migration/index.md),
test tampering by agents (S), Renovate skill audit (S).
