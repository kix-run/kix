# Experimental packages

A package in this folder may change in any Kix release, including a patch
release. The change can be one that shows no error. Each change is listed in
`CHANGELOG.md` under the heading for experimental packages.

A cluster names one as `packages.experimental.<name>`.

When a package is ready, its folder moves to `../stable/`. From then on it
breaks only in a minor release, and `packages.experimental.<name>` fails with
an error that gives the new spelling, `packages.<name>`.

A package here may have the same name as a stable package. It is then a
rework of that package, and it replaces the stable one in a minor release.
