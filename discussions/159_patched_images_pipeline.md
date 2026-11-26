# 159: Patched images pipeline, CVE to production

**Status:** RFC (draft)
**Related:** `business_discussions/54_patched_images_offering.md` (the business case), `26_images-vertical-integration.md`, `archive/138` (image pins), `../housekeeping/2026-09-28-helper-images-are-hardcoded-without-a-pin.md`

## Problem

Doc 54 proposes a Kix Enterprise feature that a customer turns on: when a
CVE affects an image running in one of their clusters, Kix finds a fixed
image, tests it against the Kix package that runs it, and delivers the
change as a reviewed plan that the in-cluster agent deploys. Kix Enterprise
records every step, so the customer can show an auditor the time from
disclosure to the fix running in production.

Doc 54 settled the business direction (Adam, 2026-10-07):

- No contractual SLA. Kix publishes measured fix times, and each customer
  sees their own.
- Upstream images first. Kix builds an image only where a customer is
  blocked and nobody else covers them (doc 54 option C).
- At first an engineer runs Claude Code in daily or hourly sessions over
  the work the pipeline cannot finish. Once there are customers, the same
  work runs unattended through the API.

This doc covers what the pipeline is made of, what exists already, and the
order to build it in.

## Proposal

### Overview

```
CVE feeds ─┐
           ▼
inventory ─▶ scan ─▶ find a fix ─▶ verify ─┬─▶ pin bump PR ─▶ customer CI ─▶ bundle
(per                                       │                                   │
cluster)                                   └─▶ agent queue                     ▼
                                               (person reviews)     plan ─▶ approve ─▶ agent deploys
                                                                                        │
                        timeline: disclosed · fix available · PR · plan · approved · running
```

The pipeline is deterministic and runs without the agent. The agent takes
only the items the pipeline cannot settle, and a person approves what it
produces. A customer's cluster changes only through a plan the customer
approved, so the agent never deploys.

### The parts

**1. Inventory.** Which images, at which digests, each customer cluster
runs, and which Kix package runs each one. The data exists:

- `kix images` lists every image in an activation, with `--sources` giving
  the resource and container (`cli/kix-cli/src/commands/images.rs`).
- `kix compliance sbom` writes one CycloneDX component per image, linked
  to its package.
- The Kix Enterprise collector already sends Pods to the API. A Pod's
  `status.containerStatuses[].imageID` is the digest actually running,
  which is what part 7 needs to tell when a fix reached production.

New: a per-image record in Kix Enterprise that joins the three, keyed on
digest, so one scan serves every cluster running that digest.

**2. Scanning.** What is inside each image, matched against CVE data.

- List the contents with Syft, and match with Grype or Trivy.
- Feeds: OSV, the GitHub advisory database, each distribution's security
  feed (Debian, Alpine, Wolfi), and CISA KEV for known-exploited CVEs.
- Match again every day without rebuilding. Most new findings are new CVEs
  in images that have not changed.

All new. Scanning is per digest, not per customer.

**3. Finding a fix.** For each finding, a candidate image, in this order:

1. A newer patch release of the same upstream image (same repository, same
   major and minor version).
2. A hardened equivalent, such as a Docker Hardened Image, if the package
   is known to work with it.
3. A Kix-built image (part 9), if one exists for this gap.

Each package needs a small policy saying which repositories and version
ranges are acceptable, and whether a hardened equivalent is allowed. A
hardened image is often non-root with no shell, which can break a package
that expects either, so this is set per package once it has been tested.

New. The policy belongs with the package in kixpkgs, so a package author
states it once for every customer.

**4. Verification.** The candidate must scan better (fewer CVEs, no new
critical ones) and must still work. Run the Kix package's tests on a kind
cluster with the candidate pinned. kixpkgs already runs kind smoke tests
(`ludo-kind`); this needs them per package and per image.

Verification is per package version and candidate, not per customer. A
customer's own overrides are checked later by their CI and by `kix plan`.

**5. The change.** Bump the pin in the customer's repository (`pins.json`,
written by `kix pin`) and open a pull request. Their CI builds and uploads
the bundle as it does today, so Kix Enterprise never builds a customer's
cluster.

This needs Kix Enterprise to act on the forge: a GitHub or Forgejo app that
can open pull requests. That is forge step 2 in the Kix Enterprise
decisions (`monorepo/src/rust/kix-enterprise/docs/decisions.md`, "PR
comments"), and it is not built.

**6. Review and deploy.** Exists: the plan, sign-off, the signed statement,
and the in-cluster deploy with kix's guard
(`monorepo/src/rust/kix-enterprise/docs/in-cluster-deploys.md`).

One addition: a policy rule that approves a plan by itself when it changes
only image digests, each bump passed part 4, and the bump stays within a
patch release. Most of the speed in a CVE-to-production time comes from not
waiting for a person, so this rule matters more than any other part. The
customer turns it on, per Kix cluster.

**7. Timeline and evidence.** One timeline per CVE per cluster:

| Event | Source |
|---|---|
| Disclosed | the CVE feed |
| Fix available | part 3 found a candidate that passed part 4 |
| PR opened | part 5 |
| Plan ready | Kix Enterprise, when the agent's plan arrives |
| Approved | sign-off |
| Running | the collector reports the new digest in every affected Pod |

These timestamps are the product's only claim when there is no SLA (doc
54 §6), so they must be exact. They go into the audit record and the
evidence export, and a page in Kix Enterprise shows them per customer and
in total.

New: a CVE record in Kix Enterprise and the page. The audit record exists.

**8. The agent's queue.** Whatever parts 2 to 5 could not settle:

- a candidate that failed verification;
- a CVE with no fixed image anywhere, which needs a backport;
- a CVE that may not apply (the code is not reachable, or the feature is
  not built), where the answer is a VEX statement rather than a new image;
- a gap that needs a Kix-built image (part 9).

Each item is a ticket with the evidence attached: the scan, the failed
test output, the package. At first an engineer works the queue with Claude
Code. Later the Claude Agent SDK runs over it unattended and opens pull
requests, and a person merges them.

The engineer-run phase measures what the unattended phase will cost: items
per day, time per item, and how often the agent's work is rejected.

`lithus/bitnami-images` already lets Claude Code fix failed builds in CI,
which is the start of this.

**9. Rebuilds for the gaps.** Only for images a customer is blocked on.
Build, sign with cosign, attach an SBOM and SLSA provenance, and publish.
`lithus/bitnami-images` does this for 12 images from Dockerfiles on
distribution packages. See "Why not Nix-built images" below for why the
gaps should be built the same way.

### What is shared and what is per customer

Parts 2, 3, 4, and 9 run once per image or package version, whatever the
number of customers. Parts 1, 5, 6, and 7 run per customer. The shared part
is where the cost advantage over vendors who staff a catalog comes from.

### Prerequisite in kixpkgs

Every image a package runs must be reachable by a pin. Today some are not:
init and helper containers in `vaultwarden`, `firezone`, and `reflector`
hardcode an image string (`reflector` runs the withdrawn
`bitnamilegacy/kubectl:1.33`). Images inside packages imported from Helm
charts must also be overridable. This is upstream work and comes first; the
housekeeping entry lists the known cases.

## Why not Nix-built images

Nix would be a good build system for these images: reproducible builds,
provenance, and nixpkgs carries its CVE patches in the package definition.
The problem is reading the result. Customers judge an image with their own
scanner (Trivy, Grype, Wiz, Snyk), and those scanners read Nix images
badly:

- Scanners find OS packages through the image's package database (`dpkg`,
  `apk`, `rpm`) and match them against that distribution's feed. A Nix
  image has no package database, only `/nix/store/<hash>-<name>-<version>`
  paths, so system libraries such as openssl and zlib mostly go
  unreported. A security team reads that as unverified, not as clean.
- Language packages are still found, from their own metadata (Python
  `METADATA`, Go build info).
- `vulnix` and `sbomnix` read the Nix store but match names against NVD, so
  they report CVEs that nixpkgs has already patched. `vulnxscan` filters
  those, but it is not the customer's scanner.
- The Nixpkgs security tracker (`NIXPKGS-YYYY-NNNN` ids) is for triage, not
  a feed scanners consume, and the `pkg:nix` package URL is not
  standardized, so Grype does not match it.

Chainguard faced the same problem with Wolfi and solved it by publishing a
security feed and getting each scanner vendor to read it. That took years
of partner work, and is a large part of its moat.

So Kix uses Nix to build Kix, and builds gap images on a distribution the
scanners already read. A Nix-built image becomes worth it if `pkg:nix` and a
nixpkgs feed reach the mainstream scanners. Shipping VEX statements for
every CVE nixpkgs has patched would also work, but each customer would have
to configure their scanner to read them, which defeats a feature meant to
be turned on with one switch.

## Order of work

1. **Measure our own clusters.** Parts 1, 2, and 7 on lab1, stage1, and Lithus
   clients, with no changes made. This gives the first real fix times, which
   is what doc 54 says to sell on.
2. **Bump our own repositories.** Parts 3, 4, and 5 in repositories we
   control, so no forge app is needed. The agent queue (part 8) starts here,
   with engineer-run sessions. Fix the kixpkgs prerequisite first.
3. **Make it a product.** The forge app, the "patched images" setting in
   Kix Enterprise (the settings system already supports a declared setting
   shown as "coming soon"), the CVE timeline page, and the auto-approve
   rule.
4. **Rebuild the gaps.** Part 9, only for images a customer is blocked on.
5. **The agent through the API.** When there are customers, and step 2 has
   shown what the queue costs.

## Open questions

1. Does the per-package fix policy (part 3) live in the package's `meta`,
   or in a separate file kixpkgs maintains? It changes more often than the
   package.
2. Should the auto-approve rule (part 6) also require the package's tests
   to have run against the customer's own overrides, which only their CI
   can do?
3. Images in packages a customer imported from Helm: covered, or only
   kixpkgs packages? Covering them means verifying against charts we do
   not maintain.
4. Which feed wins when OSV, a distribution feed, and NVD disagree on
   severity or the fixed version?
5. Does a VEX statement (CVE not applicable) count as fixed in the
   published times? If so, who signs it, and how does the customer's
   scanner learn of it?
6. Where does scanning run: in Kix Enterprise, or as a separate service
   shared by every Kix Enterprise instance? Self-hosted installs would need
   the feeds and the scan results.
