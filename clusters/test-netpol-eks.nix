# clusters/test-netpol-eks.nix: generated network policy on the eks flavor
# with network policy turned on in the Amazon VPC CNI, which writes
# standard NetworkPolicy objects.
#
# - `np/echo-server` sits behind a LoadBalancer Service, so it gets ingress
#   from outside the cluster.
# - `external-dns/route53` acts as an IAM role through IRSA, so it reaches
#   AWS STS and Route 53 on the internet, and calls the API server.
# - `data/pg` is a cnpg-cluster that backs up to S3 as an IAM role. The
#   CloudNativePG operator creates its pods, and their policy carries the
#   same credential egress.
# - `cert-manager/cert-manager` serves an admission webhook, which the API
#   server calls from the control plane's addresses in the cluster subnets.
# - The monitoring module's Prometheus scrapes node-exporter, which runs on
#   the host network, so its rule uses `cluster.network.nodeCidrs`.
#
# The addresses are examples. On EKS, pods and nodes take addresses from the
# same VPC subnets, so `nodeCidrs` and `apiServer.sources` are the subnet
# range, and `serviceCidr` gives the API server's address.
#
# Build:   kix check netpol-eks
{ kix, packages }:

kix.buildCluster {
  name = "netpol-eks";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.eks
    kix.modules.experimental.monitoring

    {
      networkPolicy.enable = true;
      cluster.flavor.eks.networkPolicy = "vpc-cni";
      cluster.network = {
        serviceCidr = "10.100.0.0/16";
        nodeCidrs = [ "192.168.0.0/16" ];
        apiServer.sources = [ { cidr = "192.168.0.0/16"; } ];
      };

      instances.storage.gp3.package = kix.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          name = "gp3";
          storageClassName = "gp3";
        };
      };

      instances.np.echo-server = {
        package = packages.echo-server;
        config.service.type = "LoadBalancer";
      };

      instances.external-dns.route53 = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.aws {
          roleArn = "arn:aws:iam::111122223333:role/external-dns";
        };
        config = {
          provider = "aws";
          policy = "upsert-only";
          txtOwnerId = "netpol-eks";
          extraArgs = [ "--domain-filter=example.com" ];
        };
      };

      instances.cnpg-system = {
        cnpg-operator.package = packages.cnpg-operator;
        cnpg-barman-cloud.package = packages.experimental.cnpg-barman-cloud;
      };
      instances.data.pg = {
        package = packages.cnpg-cluster;
        deps.storageCredentials = kix.cloudIdentity.aws {
          roleArn = "arn:aws:iam::111122223333:role/pg-backup";
        };
        config = {
          storage.size = "10Gi";
          backup.destinationPath = "s3://example-pg-backups/data";
        };
      };

      instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;

      monitoring.enabled = true;
      # Test values only.
      instances.monitoring-system.grafana-admin = {
        package = packages.secret;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "test-only";
        };
      };
    }
  ];
}
