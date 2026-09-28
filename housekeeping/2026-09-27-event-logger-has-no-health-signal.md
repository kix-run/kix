# 2026-09-27 · `kix/packages/event-logger` · The event watcher has no health signal, so `reliability.hasProbes` warns and a stalled watch goes unnoticed.

The script in the package's ConfigMap serves no port and writes no
heartbeat. A liveness probe has nothing to check, and a watch stream
that stops delivering events leaves the pod Running and Ready. A probe
needs the script to expose one, for example by touching a file on each
event and on each watch reconnect.
