+++
kind = "note"
packages = ["experimental/tailscale"]
+++
`tailscale` now runs the Tailscale Kubernetes operator 1.104.7 instead of 1.102.4. The operator keeps its tailnet device and every tailscale.com resource. The first deploy moves each proxy the operator manages to the 1.104.7 proxy image, so each proxy pod restarts once and its tailnet traffic stops for a moment. PeerRelay gains `service.port` and `staticEndpoints`, and DNSConfig gains `nameserver.pod.imagePullSecrets`. The API server proxy now identifies a caller only by the connection's source address and ignores the `X-Forwarded-For` header. To go back, deploy the older package. The older CRDs drop the new PeerRelay and DNSConfig fields from stored resources.
