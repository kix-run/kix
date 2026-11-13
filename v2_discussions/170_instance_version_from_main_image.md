# 170: The library finds the image an instance's version comes from

**Status:** Draft
**Related:** issue #87, PR #92 (`meta.instanceVersion`, `kix.image.version`)

## Context

PR #92 made an instance report the version it runs, not the package's
default. One rule in `kix/lib/meta.nix` (`instanceVersion`) decides the
version: the instance's `version` setting, then the package's
`out.version`, then `meta.version`.

For `out.version` to name the running version, each package reads it from
its main image:

```nix
out = { version = kix.image.version config.image; ... };
```

66 packages carry that line. A new check in `kix/package-eval.nix`
(`checkPublishedVersion`) fails a package whose default image tag names
`meta.version` and that publishes no `out.version`. The package-authoring
and package-review skills tell authors to add the line.

## Problem

Every package states the same fact by hand, and a check makes sure none
forgets. The check already knows the answer: to decide whether it applies,
it searches the instance's config for an image whose default tag names
`meta.version`. That image is the one the line reads.

The library is missing one concept: the image an instance's version comes
from. It can work that out without any help from the package.

## Proposal

`instanceVersion` gains one step, before it falls back to `meta.version`.

1. Search the package's option defaults for image options (`repository`
   and `tag`) whose default tag names `meta.version`. This is the search
   `imagesOf` and `tagNamesVersion` do in the check today.
2. If exactly one option path matches, read the tag the instance set at
   that path and return `kix.image.version` of it. That is null when the tag
   names no version, as it is today.
3. If none matches, or more than one matches with different configured
   tags, fall through to `meta.version`.

Order of the rule after the change:

1. The instance's `version` setting.
2. `out.version` the package sets. A package still sets it when the
   version is not its main image's tag, such as cnpg-cluster's full
   Postgres version, or a contract that carries `version`.
3. The version of the main image, found as above.
4. `meta.version`.

Then:

- The 66 `kix.image.version config.image` lines go, except where a
  contract needs `out.version` as a field (valkey and keycloak publish it to
  consumers). Those could read the instance version from the library
  instead, see the open questions.
- `checkPublishedVersion` goes. The library's search replaces it.
- The skills drop the rule.

## Costs and risks

- The search walks option defaults on every instance. It runs once per
  instance, three levels deep, as the check does now. It should be cheap,
  but measure it on homelab-kind.
- A package can have two images whose default tags both name its version.
  An example is an app and a migration image from the same release. Step 3
  handles this when the user changes both. When the user changes only one,
  the library cannot know which is the main software. It could then report
  no version and warn, or the package could name the option in `meta`.
- It is less explicit. A reader of a package no longer sees where the
  version comes from. The docs for `instanceVersion` would have to say it.

## Alternatives considered

- **Keep PR #92 as it is.** It works, and every package says where its
  version comes from. The cost is the repeated line, the check, and a rule
  every new package must follow.
- **The package names its main image in `meta`** (for example
  `meta.versionFrom = [ "image" ]`). The search goes away, at the cost of
  a new field in every package. It is still one line per package, so it
  saves little over today.

## Open questions

1. Should contracts that carry `version` (valkey, keycloak's OIDC
   provider, ClickHouse) read it from the instance version the library
   computes, so packages set it nowhere?
2. When two images match and the user changed only one, should the
   instance report no version, or should the build stop?
