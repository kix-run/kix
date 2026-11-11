+++
kind = "added"
library = ["packages.experimental", "kix.contracts.experimental"]
+++
Packages and contracts have a stability level. A stable package or contract
breaks only in a minor release. An experimental one may break in any release,
and `CHANGELOG.md` lists those changes under "Breaking in experimental packages
and contracts". A cluster names an experimental package as
`packages.experimental.<name>`, and a package reads an experimental contract
as `kix.contracts.experimental.<name>`. Stable ones keep their names, and are
also reachable as `packages.stable.<name>` and `kix.contracts.stable.<name>`.
When an experimental package or contract becomes stable, its experimental name
fails with an error that gives the stable one. No package is experimental yet.
