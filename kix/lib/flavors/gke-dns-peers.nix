# Where pods on GKE send DNS queries, as the `platform-dns` import's
# `dnsPeers`. A GKE cluster uses one or two of these, depending on
# NodeLocal DNSCache and Cloud DNS. A rule for a peer the cluster does not
# run opens only port 53 to that address, so the flavours list all four.
[
  # kube-dns, without NodeLocal DNSCache. The `kube-dns` Service selects
  # these labels on a live GKE cluster; queries to the pods themselves were
  # not tested there.
  {
    namespace = "kube-system";
    podSelector."k8s-app" = "kube-dns";
  }
  # NodeLocal DNSCache, which GKE turns on by default from 1.34. Tested on a
  # live GKE Standard cluster.
  {
    namespace = "kube-system";
    podSelector."k8s-app" = "node-local-dns";
  }
  # Cloud DNS answers at the metadata server and at the NodeLocal DNSCache
  # address (https://cloud.google.com/kubernetes-engine/docs/how-to/cloud-dns).
  # Whether an address rule reaches them under GKE Dataplane V2 has not been
  # tested.
  { cidr = "169.254.169.254/32"; }
  { cidr = "169.254.20.10/32"; }
]
