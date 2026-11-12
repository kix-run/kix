# Experimental contracts

A contract in this folder may change in any Kix release, including a patch
release. Each change is listed in `CHANGELOG.md` under the heading for
experimental packages and contracts.

A package reads one as `kix.contracts.experimental.<name>`. Only an
experimental package may read one. A stable package reads stable contracts
only, so that it never breaks in a patch release.

When a contract is ready, its file moves to `../stable/`. From then on it
breaks only in a minor release, and `kix.contracts.experimental.<name>`
fails with an error that gives the new spelling, `kix.contracts.<name>`.
