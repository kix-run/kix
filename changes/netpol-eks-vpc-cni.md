+++
kind = "added"
+++
Generated network policy now works on EKS when the Amazon VPC CNI add-on enforces it. Set `cluster.flavor.eks.networkPolicy = "vpc-cni"` after turning on `enableNetworkPolicy` in the add-on, and `networkPolicy.enable = true` writes standard `NetworkPolicy` objects. The default, `"none"`, matches how EKS creates a cluster, and with it `networkPolicy.enable = true` stops the build and names both settings. On EKS, Kix takes the API server's address from `cluster.network.serviceCidr`, needs `cluster.network.apiServer.sources` (the cluster subnets) for packages that serve webhooks, and reports through `security.networkPolicyWidened` that `world` rules and node ranges also match pods, and that a new pod sends traffic for about one second before its policy applies.
