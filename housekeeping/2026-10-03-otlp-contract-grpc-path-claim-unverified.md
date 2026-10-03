# 2026-10-03 · `kix/lib/vocab/otlp-endpoint.nix` · The comment that a gRPC exporter rejects a path in its endpoint URL has no source behind it.

The comment above `isBaseUrl` says "a gRPC exporter rejects a path, so the URL ends at the port". No pinned exporter source was checked. The OTel Go `otlptracegrpc` exporter and the collector's `otlp_grpc` exporter may ignore the path instead of rejecting it. The no-path rule itself is right for OTLP/HTTP, where exporters append `/v1/traces`. Read both exporters' endpoint parsing, then state what they do or drop the gRPC clause.
