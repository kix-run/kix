# Pipe-friendly resource composition helpers.
#
# These functions produce plain attrsets suitable for scope.mkResource.
# They are NOT resources themselves — pipe into scope.mkResource to seal.
#
# Usage:
#   service = self.deployment
#     |> scope.expose { name = "my-svc"; }
#     |> scope.mkResource;
#
#   ingress = self.service
#     |> scope.ingress { name = "my-ing"; host = "example.com"; }
#     |> clusterIssuer.out.withCert
#     |> scope.mkResource;

{ lib }:

rec {

  # Extract service-compatible port entries from a workload resource.
  # Reads spec.template.spec.containers[*].ports from the workload's rawManifest.
  extractServicePorts = workload:
    let
      containers = workload.rawManifest.spec.template.spec.containers or [];
      allPorts = builtins.concatMap (c: c.ports or []) containers;
    in
    map (cp:
      { port = cp.containerPort; protocol = cp.protocol or "TCP"; }
      // lib.optionalAttrs (cp ? name) { name = cp.name; targetPort = cp.name; }
    ) allPorts;

  # Create a Service attrset from a workload resource (Deployment, StatefulSet, DaemonSet).
  #
  # Auto-derives:
  #   - spec.selector from workload.out.selector
  #   - spec.ports from workload container ports (override with `ports`)
  #
  # Consumed config: name, type, ports
  # Passthrough to mkResource: outputs, requires, labels, annotations, extra, etc.
  expose =
    {
      name,
      type ? "ClusterIP",
      ports ? null,
      ...
    }@cfg:
    workload:
    let
      finalPorts = if ports != null then ports else extractServicePorts workload;
      firstPort = if finalPorts != [] then toString (builtins.head finalPorts).port else null;
      autoOutputs = lib.optionalAttrs (firstPort != null) { port = firstPort; };
      passthrough = removeAttrs cfg [ "name" "type" "ports" ];
    in
    {
      apiVersion = "v1";
      kind = "Service";
      inherit name;
      spec = {
        inherit type;
        selector = workload.out.selector;
        ports = finalPorts;
      };
      outputs = autoOutputs // (cfg.outputs or {});
    } // removeAttrs passthrough [ "outputs" ];

  # Create an Ingress attrset from a service resource.
  #
  # Auto-derives:
  #   - backend service name from service.out.name
  #   - backend port from service.out.port (override with `port`)
  #
  # Consumed config: name, host, path, pathType, port, className, tls
  # Passthrough to mkResource: annotations, labels, requires, extra, etc.
  ingress =
    {
      name,
      host,
      path ? "/",
      pathType ? "Prefix",
      port ? null,
      className ? null,
      tls ? [],
      ...
    }@cfg:
    service:
    let
      servicePort =
        if port != null then port
        else if service ? out.port then
          builtins.fromJSON (builtins.unsafeDiscardStringContext service.out.port)
        else
          throw "ingress: service '${service.name or "unknown"}' has no out.port — specify port explicitly";
      passthrough = removeAttrs cfg [ "name" "host" "path" "pathType" "port" "className" "tls" ];
    in
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      inherit name;
      spec = {
        rules = [
          {
            inherit host;
            http.paths = [
              {
                inherit path pathType;
                backend.service = {
                  name = service.out.name;
                  port.number = servicePort;
                };
              }
            ];
          }
        ];
      }
      // lib.optionalAttrs (className != null) { ingressClassName = className; }
      // lib.optionalAttrs (tls != []) { inherit tls; };
    } // passthrough;

}
