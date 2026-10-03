# The Gateway API v1 Listener option type and the listeners a Gateway
# renders from it. Used by envoy-gateway and traefik, which both render a
# Gateway from a `listeners` option and publish the result on out.listeners.
{ lib }:
let
  inherit (lib) mkOption types;
  optional =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
in
{
  # Fields left null are not rendered.
  type = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      port = mkOption { type = types.port; };
      protocol = mkOption {
        type = types.enum [
          "HTTP"
          "HTTPS"
          "TLS"
          "TCP"
          "UDP"
        ];
      };
      hostname = optional types.str;
      tls = optional (
        types.submodule {
          options = {
            mode = optional (
              types.enum [
                "Terminate"
                "Passthrough"
              ]
            );
            certificateRefs = optional (types.listOf (types.attrsOf types.anything));
            frontendValidation = optional (types.attrsOf types.anything);
            options = optional (types.attrsOf types.str);
          };
        }
      );
      allowedRoutes = optional (
        types.submodule {
          options = {
            namespaces = optional (
              types.submodule {
                options = {
                  from = optional (
                    types.enum [
                      "All"
                      "Same"
                      "Selector"
                    ]
                  );
                  selector = optional (types.attrsOf types.anything);
                };
              }
            );
            kinds = optional (types.listOf (types.attrsOf types.anything));
          };
        }
      );
    };
  };

  # An HTTP listener on 80 and an HTTPS listener on 443, both admitting
  # routes from every namespace. The HTTPS one has no certificate yet, so
  # `active` drops it until the instance sets `tls.certificateRefs`.
  defaults = [
    {
      name = "http";
      port = 80;
      protocol = "HTTP";
      allowedRoutes.namespaces.from = "All";
    }
    {
      name = "https";
      port = 443;
      protocol = "HTTPS";
      tls = {
        mode = "Terminate";
        certificateRefs = [ ];
      };
      allowedRoutes.namespaces.from = "All";
    }
  ];

  # The listeners to render: an HTTPS listener without certificateRefs is a
  # placeholder the cluster operator has not configured yet and is left out.
  # Unset fields are dropped here rather than at rendering, so they stay out
  # of the Gateway's identity hash.
  active =
    listeners:
    map (lib.filterAttrsRecursive (_: v: v != null)) (
      builtins.filter (
        l:
        l.protocol != "HTTPS"
        || (l.tls != null && l.tls.certificateRefs != null && l.tls.certificateRefs != [ ])
      ) listeners
    );
}
