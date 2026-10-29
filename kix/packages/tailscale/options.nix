# Options of the tailscale package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  tag,
  operandDigests,
}:
{
  image = kix.options.image {
    repository = "docker.io/tailscale/k8s-operator";
    inherit tag;
    digest = "sha256:3c8958c42fb3c46068e8553e11b944f2133b4671d4f36c86adc11f206746bf34";
    description = "Image of the operator. Its major.minor must match the vendored CRDs and RBAC. Each operand image defaults to this repository with its own last path segment (`docker.io/tailscale/<name>`) and to this tag.";
  };

  operandImages = {
    tailscale = kix.options.image {
      repository = "docker.io/tailscale/tailscale";
      inherit tag;
      digest = operandDigests.tailscale;
      tagText = "config.image.tag";
      pullPolicy = null;
      description = "Image of the proxies the operator creates (`PROXY_IMAGE`). Listed in `out.extraImages`. The operator sets their pull policy, so `pullPolicy` must stay null.";
    };
    k8s-proxy = kix.options.image {
      repository = "docker.io/tailscale/k8s-proxy";
      inherit tag;
      digest = operandDigests.k8s-proxy;
      tagText = "config.image.tag";
      pullPolicy = null;
      description = "Image of the kube-apiserver ProxyGroup proxies (`K8S_PROXY_IMAGE`). Listed in `out.extraImages`. The operator sets their pull policy, so `pullPolicy` must stay null.";
    };
    k8s-nameserver = kix.options.image {
      repository = "docker.io/tailscale/k8s-nameserver";
      inherit tag;
      digest = operandDigests.k8s-nameserver;
      tagText = "config.image.tag";
      pullPolicy = null;
      description = "Default nameserver image of `out.mkDNSConfig`. Listed in `out.extraImages`. DNSConfig has no pull policy field, so `pullPolicy` must stay null.";
    };
    tsrecorder = kix.options.image {
      repository = "docker.io/tailscale/tsrecorder";
      inherit tag;
      digest = operandDigests.tsrecorder;
      tagText = "config.image.tag";
      description = "Default image and pull policy of `out.mkRecorder`. Listed in `out.extraImages`.";
    };
  };

  resources = kix.options.resources {
    requests = {
      cpu = "100m";
      memory = "128Mi";
    };
    limits = {
      cpu = "2";
      memory = "1Gi";
    };
  };

  env = kix.options.env // {
    description = "Upstream operator variables such as `OPERATOR_HOSTNAME`, `OPERATOR_INITIAL_TAGS`, `PROXY_TAGS`, `PROXY_FIREWALL_MODE`, `OPERATOR_LOGGING`, `TS_NO_LOGS_NO_SUPPORT`, and `OPERATOR_LOGIN_SERVER` (an https URL on port 443). A value is a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The OAuth client comes from the `oauthCredentials` dependency. Variables the package sets or does not support are refused.";
  };

  metrics = kix.options.monitor;

  defaultProxyClass = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "ProxyClass for proxies that name none (`PROXY_DEFAULT_CLASS`). Must be a key of `proxyClasses`.";
  };

  proxyClasses = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
    default = { };
    description = "ProxyClass custom resources, keyed by name, each as its `spec`. Applied once the operator runs.";
  };

  connectors = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options.proxyClass = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Key of `proxyClasses` whose ProxyClass the Connector uses.";
        };
      }
    );
    default = { };
    description = "Connector custom resources, keyed by name, each as its `spec`. `proxyClass` names a key of `proxyClasses`; build Connectors that reference an external ProxyClass with `out.mkConnector`.";
  };
}
