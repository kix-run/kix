# 172a: How many version updates the Kix package set needs

**Status:** Analysis
**Related:** `172_package_version_upkeep.md`

Period measured: 14 November 2025 to 13 November 2026. Source: GitHub releases
of each package's upstream project, read with `gh api` on 14 November 2026.
The scripts and data (`fetch.py`, `analyze.py`, `releases.csv`,
`per-package.csv`) are not in the repository yet. They are in
`/scratch/worktrees/upkeep/_keep/release-rates/`.

Two counts are used throughout:

- **Updates we would take.** We follow the newest stable line. In date order,
  we count each time the highest version rises. A fix on an older line does not
  count. This is the number of pull requests an upkeep process would open.
- **All stable releases.** Every stable release, including fixes on older lines.
  Pre-releases, release candidates, betas, and drafts are left out of both.

Each step is major (1.x to 2.0), minor (1.4 to 1.5), or patch (1.4.2 to 1.4.3).

## 1. Headline

The measured set has 69 packages that run upstream software. They come from
61 distinct upstreams, because some packages share one (three VictoriaMetrics
packages, four ClickHouse packages, two Immich packages, two that run Vector,
and two that run PostgreSQL). One package, `prometheus-default-rules`, is left
out of the headline (see section 7). With it, add about 25 updates a month.

| Per month | Major | Minor | Patch | Total |
|---|---|---|---|---|
| Per package, mean | 0.6 | 33.8 | 86.6 | 121 |
| Per package, lowest month | 0 | 26 | 45 | 74 |
| Per package, highest month | 2 | 43 | 149 | 187 |
| Per distinct upstream, mean | 0.5 | 27.2 | 66.8 | 94 |
| Per distinct upstream, lowest month | 0 | 22 | 38 | 61 |
| Per distinct upstream, highest month | 2 | 32 | 106 | 134 |

One upstream release can be one pull request that touches several packages.
So about 94 pull requests a month is the better estimate of work for this set.

Majors are rare: 7 in the year across all packages. But 19 packages are below
1.0, and there a minor step is the breaking step by convention. They had 111
such steps. Counting those, a breaking or possibly breaking update arrives
about 10 times a month.

Five packages use calendar versions: `cloudflared` (2026.9.3) and the four
ClickHouse packages (26.3.33.24). For these we count a new year or month in
the version (a new ClickHouse long-term line, or a new cloudflared month) as
minor, and anything after it as patch. They had 18 "minor" and 292 "patch"
updates; 280 of the patches are ClickHouse, counted once per package.

## 2. Per package

| Per package per month | Mean | Median |
|---|---|---|
| Major | 0.008 | 0 |
| Minor | 0.49 | 0.25 |
| Patch | 1.26 | 0.58 |
| Total | 1.75 | 1.00 |

The spread is wide. A quarter of packages take 0.5 updates a month or fewer,
and a quarter take 2.3 or more. The mean is well above the median because a
few projects release very often. The five busiest upstreams produce 37% of
all updates:

- `n8n`: 164 updates in the year (48 minor, 115 patch, 1 major), weekly releases.
- `reflector`: 83, nearly all automated patch releases, up to 14 a month.
- ClickHouse long-term lines: 70 (68 patch builds), counted once per package.
- `filebrowser`: 52. `metabase`: 48.

The quietest: `firezone` (0; the 0.7 line it pins has had no release since
2023), `smartctl-exporter` (1), `plausible` (2), `metrics-server` (3), and
`snapshot-controller` (3). Eighteen upstreams had 6 or fewer updates.

## 3. Monthly totals (updates we would take)

Months run from the 14th to the 13th of the next month.

| Month from | Per package: major / minor / patch | Total | Per upstream: major / minor / patch | Total |
|---|---|---|---|---|
| 2025-11-14 | 1 / 37 / 59 | 97 | 1 / 32 / 55 | 88 |
| 2025-12-14 | 0 / 29 / 45 | 74 | 0 / 23 / 38 | 61 |
| 2026-01-14 | 2 / 35 / 73 | 110 | 2 / 29 / 62 | 93 |
| 2026-02-14 | 0 / 33 / 69 | 102 | 0 / 28 / 62 | 90 |
| 2026-03-14 | 0 / 43 / 111 | 154 | 0 / 32 / 77 | 109 |
| 2026-04-14 | 1 / 31 / 69 | 101 | 1 / 24 / 62 | 87 |
| 2026-05-14 | 1 / 35 / 81 | 117 | 1 / 30 / 72 | 103 |
| 2026-06-14 | 2 / 26 / 76 | 104 | 1 / 22 / 65 | 88 |
| 2026-07-14 | 0 / 31 / 81 | 112 | 0 / 25 / 71 | 96 |
| 2026-08-14 | 0 / 32 / 88 | 120 | 0 / 23 / 55 | 78 |
| 2026-09-14 | 0 / 38 / 149 | 187 | 0 / 30 / 76 | 106 |
| 2026-10-14 | 0 / 35 / 138 | 173 | 0 / 28 / 106 | 134 |

December is quiet (holidays). The high per-package totals in September and
October come mostly from ClickHouse patch builds (counted four times), n8n,
reflector, cloudflared, and Immich. The minor count is steady at 22 to 32 a
month per upstream.

## 4. Rule of thumb

For a repository of N packages like these, expect each month roughly:

- **Patch:** 0.8N to 1.3N
- **Minor:** 0.35N to 0.5N
- **Major:** about N/120, so one major per 10 packages per year
- **Total:** 1.3N to 1.8N; a resampling test puts the mean between 1.4N and 2.2N

The low end of each range drops the busiest and quietest 10% of packages; the
high end is the plain mean. Which end applies depends mostly on whether the
set includes fast projects like n8n, reflector, ClickHouse, or metabase. One
such package adds 4 to 14 updates a month on its own. If packages share
upstreams, as here, pull requests are about 20% fewer than package updates.

Example: 100 packages gives roughly 80 to 130 patch, 35 to 50 minor, and about
one major update a month.

## 5. Updates we would take, compared with all stable releases

Per distinct upstream, there were 1,728 stable releases and 1,133 updates we
would take. So about a third of stable releases (34%) are fixes on older lines.
Per package the figures are 2,344 and 1,451 (38%).

The gap sits in a few projects that maintain several lines at once:
`metabase` (151 releases, 48 taken), `grafana` (106, 27), `n8n` (278, 164),
VictoriaMetrics (87, 29, because of its long-term lines), ClickHouse (124 on
long-term lines, 70 taken), `traefik` (71, 33), `cilium` (38, 14), `valkey`
(28, 8), and PostgreSQL (25, 5, since every fix release covers five majors).
Most other projects ship only on their newest line, so the two counts match.

## 6. Batching

If a package takes patch updates at most once in each 7-day period, and takes
every minor and major on its own:

- Per package: 92 pull requests a month (from 121).
- Per upstream: 76 a month (from 94).

If patch updates are taken at most once a month per package:

- Per package: 69 a month. Per upstream: 58 a month.

Monthly batching removes about 40% of the work. Nearly all of the saving comes
from the fast projects. n8n alone drops from 164 to 61 a year. These numbers
slightly overstate the work, because a minor update in the same period would
also carry the pending patch.

## 7. Limits of the data

**Packages left out or not measured:**

- `envoy-gateway`: pins no software. It writes Gateway API objects; the
  controller is installed separately. Its `1.1.0` is the package's own version.
- `stackgres-cluster`: pins no image. It picks the newest PostgreSQL minor
  that the StackGres operator's release ships, so its updates arrive with
  `stackgres-operator` updates.
- `secret-echo`: a test package with a floating `nginx:1.27-alpine` tag.
- `prometheus-default-rules`: measured but left out of the headline. It copies
  rule files from the kube-prometheus-stack chart 84.5.0. That chart had 297
  releases in the year (14 major), mostly for reasons unrelated to the rules.
  Counted in full, it adds about 25 updates and one major a month.
- `firezone`: measured as zero. It pins the self-hosted 0.7 line, which ended in
  2023. The real work is a replacement, not updates.
- No upstream software: `persistent-volume-claim`, `priority-class`, `secret`,
  `secret-ref`, `storage-classes`, `cluster-issuer`, `cnpg-database`,
  `external-secret`, `oidc-client`, `service-ref`, and `stackgres-object-storage`.
  They write Kubernetes or operator objects only.

**Choices and guesses:**

- Tag formats: each upstream has a pattern in `fetch.py`, checked against the
  pinned version. Examples: `controller-v1.15.1`, `gha-runner-scale-set-0.14.2`,
  `infisical-k8-operator/v0.11.10`, `n8n@2.41.5`, `release-0.27.3`,
  `pgbouncer_1_25_2`, `REL_18_6`, and `v26.3.33.24-lts`.
- No GitHub releases: PostgreSQL, StackGres (GitHub mirror of a GitLab
  project), and `dns_exporter` use tags. Their dates are tag or commit dates,
  which can be a few days before the announcement. The kube-prometheus-stack
  chart uses its Helm repository index.
- Release lines: ClickHouse follows long-term lines only, because the packages
  pin 26.3 LTS. Following every monthly ClickHouse release instead gives 75
  updates a year (12 minor). `echo-server` follows nginx's even-numbered stable
  branch; mainline would give 15. n8n relies on upstream marking betas as
  pre-releases. Tailscale publishes only its stable even-numbered minors.
- Grafana security releases (`13.0.1+security-01`) count as patches.
- Only the main image of each package is counted. Sidecars and helpers also pin
  versions: kubectl, CSI sidecars, `k8s-sidecar`, `redis_exporter`, Velero
  plugins, the Altinity metrics exporter, and the VectorChord extension for
  Immich. So the totals are a floor.
- `smartctl-exporter` pins chart 0.16.0 and image 0.14.0; we counted the image.

**History shorter than 12 months:** none. Every upstream had releases before
the period, so each has a starting point.

**Why last year may be a poor guide:**

- Several pins are well behind: `kubevirt` 1.5.0 (now 1.9.1), `cdi` 1.62.0,
  `caddy` 2.10.0, `coredns` 1.13.1, and `smartctl-exporter` 0.14.0. Catching up
  is one-off work on top of these rates.
- PostgreSQL 19 is at its second release candidate, so a major update for
  `cnpg-cluster` and `stackgres-database` is due within weeks. Majors are few
  (7 in the year), so their rate is the least certain number here.
- `reflector` releases in automated bursts (2 to 14 a month), and the
  ingress-nginx project has announced its retirement. Both rates may change.
- Busy projects decide the total, so adding or dropping one moves it a lot.

## Checks by hand

Three upstreams were compared with `gh release list`, which uses a different
API path from the script, and counted by hand. All three match the script.

- cert-manager: 23 releases, 5 of them alpha or beta, so 18 stable. Taken:
  2 minor (1.20.0, 1.21.0) and 9 patch. The 7 releases on older 1.18, 1.19,
  and 1.20 lines are not taken. Script: 18 stable, 2 minor, 9 patch.
- vaultwarden: 16 releases, all stable, one line at a time. Taken: 3 minor
  (1.35.0, 1.36.0, 1.37.0) and 13 patch. Script: the same.
- external-dns: 5 app releases (v0.20.0 to v0.24.0), each a minor step. Chart
  releases are excluded, and so is v0.23.1, which upstream marked pre-release.
  Script: 5 minor, 0 patch.
