+++
kind = "added"
state = true
library = ["packages"]
+++
Each `PackageInstance` record now names the package its instance runs, in `spec.package`. The value is the id that release notes use: the package's name for a stable package, such as `harbor`, and `experimental/<name>` for an experimental one, such as `experimental/coredns`. A tool that reads a cluster can now tell which instances a release note applies to. Each package in `packages` carries the same id, as `packages.<name>.id`. An import, a package defined in your own project, and a function of your own that calls a Kix package record no id. The first deploy after you upgrade applies every `PackageInstance` again to add the field, and restarts nothing.
