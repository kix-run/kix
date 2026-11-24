# 2026-11-24 · `cli/kix/src/cluster` · One `kix deploy` opened 114 TCP connections and listed the Activation records 7 times.

Measured on kind through a TCP proxy, with the `homelab-kind` cluster. A deploy that changed 6 objects opened 114 connections to the API server, where a deploy of the same build opened 1. Each new connection costs TLS round trips on a real link. I did not find which code opens them. The same deploy listed all Activation records 7 times (5 times when nothing changed), and one record was 97 KB, so the list was 195 KB each time.
