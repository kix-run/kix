# 2026-10-02 · `cli/kix-cli/src/commands/diff.rs` · `kix diff` reports 14 changed and 19 removed packages on a ludo-kind deploy that `kix deploy` calls identical.

Seen in the W6 kind run K2 right after a successful deploy and again at the end, when `kix deploy` printed "activation identical to active ... Nothing to apply". The output (scratchpad `rework/kind/k2/diff-final.log`) mixes several kinds of noise:
- every CRD, Service, and Secret reference marker (`crd-ref-*`, `service-ref-*`, `secret-ref-*`) shows once as a removed package of its own and once as an added PackageInstance of the package that declares it;
- every Secret written with `stringData` shows `+ $.stringData`, a field the API server never stores;
- fields the API server fills in or drops: `fieldRef.apiVersion: "v1"`, `env: []`, `envFrom: []`, `readOnly: false`, `apiVersion` and `kind` inside `volumeClaimTemplates`, `readinessProbe.initialDelaySeconds: 0`, `template.metadata.annotations: null`;
- type mismatches: a CPU limit `"1"` against `1`, `failureThreshold` 3 against null;
- operator defaults: StackGres adds `publisher: com.ongres` to each SGCluster extension and the diff compares the list by index;
- the ingress-nginx admission Jobs, which their TTL deleted, show as added;
- the summary names an activation other than the current one (`2026-09-30-diff-names-a-different-current-activation.md`).
No real drift was found among them, so a reader cannot use `kix diff` to tell whether a cluster matches its build.
