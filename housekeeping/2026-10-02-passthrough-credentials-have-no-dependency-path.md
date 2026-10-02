# 2026-10-02 · `kix/packages/alertmanager` · A receiver credential reaches Alertmanager only through a Secret named by string.

The package refuses inline credentials in `settings` and points at the `_file` keys, but the file comes from `extraSpec.secrets = [ "<name>" ]`, a plain Secret name. The deploy does not wait for that Secret, nothing checks that it holds the key the `_file` path reads, and a typo surfaces only when Alertmanager fails to load its configuration. Grafana's `datasources` has the same gap through `env` and `kix.untrackedRef`.

The repository has no standard practice for credentials inside a program-config passthrough (`settings`, `datasources`): how a package takes Secrets the program reads by path or variable, as dependencies with declared keys, when the set of Secrets is the user's to choose. Each package improvises its own answer.

Decision required from Adam: the standard way for a package to take user-chosen credential Secrets for a passthrough (a list of secret dependencies, a mount helper, or something else), recorded in docs-legacy/BEST-PRACTICES.md and the package-review skill.
