# Experimental modules

A module in this folder may change in any Kix release, including a patch
release. Each change is listed in `CHANGELOG.md` under the heading for
experimental packages and contracts.

A cluster reads one as `kix.modules.experimental.<name>`. A module may name
experimental packages. A stable module names stable packages only.

When a module is ready, its file moves to `../stable/`. From then on
`kix.modules.experimental.<name>` fails with an error that gives the new
spelling, `kix.modules.<name>`.
