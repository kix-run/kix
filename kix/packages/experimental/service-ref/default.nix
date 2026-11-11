# service-ref: a Service that Kix does not render, such as a database
# another tool installed, for an instance to take as a dependency.
#
#   instances.legacy.old-db = {
#     package = packages.experimental.service-ref;
#     config = {
#       name = "old-db";
#       selector."app.example.com/cluster" = "old-db";
#       ports = [ { port = 5433; targetPort = 5432; } ];
#     };
#   };
#
# A consumer wires it with `deps.<name> = ref.legacy.old-db` and dials
# `out.fqdn` on `out.port`. The deploy waits until the Service has ready
# endpoints.
#
# Network policy: `selector` names the pods behind the Service, and
# `targetPort` the port those pods listen on, because a policy matches the
# pod and its port, not the Service. A consumer that dials `out.fqdn` gets
# egress to those pods. Kix also writes an ingress policy on those pods that
# admits the consumer. With network policy on, Kix writes its default-deny
# policy in this instance's namespace too, as for any instance. Cilium then
# refuses traffic to and from pods there that no policy admits. Check what
# else reaches those pods, and what they reach, before the first deploy.
#
# Exposes (`root.out`, `root` = the Service marker):
#   out.name, out.fqdn  The Service's name and DNS name.
#   out.port            The first entry of `ports`.
#   out.ports           `ports`.
#   out.selector        `selector`.

{
  scope,
  lib,
}:

{
  meta = {
    description = "Reference to a Service that Kix does not render";
    owner = "platform";
  };

  options = {
    name = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[a-z]([-a-z0-9]{0,61}[a-z0-9])?");
      default = null;
      description = "Name of the Service, a DNS-1035 label. Null uses the instance name.";
    };
    selector = lib.mkOption {
      type = lib.types.addCheck (lib.types.attrsOf lib.types.nonEmptyStr) (s: s != { });
      example = {
        "app.example.com/cluster" = "old-db";
      };
      description = "Labels of the pods behind the Service, which network policy selects. For a Service without a selector, such as one whose endpoints a controller writes, give the labels of the pods those endpoints name.";
    };
    ports = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.submodule {
          options = {
            port = lib.mkOption {
              type = lib.types.port;
              description = "Port of the Service, which clients dial.";
            };
            targetPort = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Port the pods listen on, as a number. Null means the same as `port`.";
            };
            protocol = lib.mkOption {
              type = lib.types.enum [
                "TCP"
                "UDP"
                "SCTP"
              ];
              default = "TCP";
              description = "Protocol of the port.";
            };
          };
        }
      );
      example = [
        {
          port = 5433;
          targetPort = 5432;
        }
      ];
      description = "Ports of the Service. The first is `out.port`.";
    };
  };

  build =
    {
      self,
      config,
      ...
    }:
    let
      ref = scope.mkServiceRef {
        name = if config.name != null then config.name else scope.instanceName;
        inherit (config) selector;
        ports = map (
          p:
          {
            inherit (p) port protocol;
          }
          // lib.optionalAttrs (p.targetPort != null) { inherit (p) targetPort; }
        ) config.ports;
      };
    in
    {
      inherit ref;
      root = self.ref;
    };
}
