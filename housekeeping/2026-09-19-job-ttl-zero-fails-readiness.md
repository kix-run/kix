# 2026-09-19 · `cli/kix/src/cluster/readiness.rs`, `kix/packages/ingress-nginx` · A Job with `ttlSecondsAfterFinished: 0` fails its readiness check and cancels everything downstream.

The apiserver deletes the Job the moment it completes, so the deploy's
next fetch gets a 404 and reports `failed to fetch resource for
readiness check`, then cancels every successor: on the harbor smoke
cluster that took out ingress-nginx, the Ingress and the Activation.
The ingress-nginx package copied the value from the Helm chart, where a
hook Job is reaped by Helm anyway. Whether the CLI should read a vanished
finished Job as success is a separate question from the package value.
