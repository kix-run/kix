# kixlib — pure composition helpers for kix packages.
#
# These functions have no scope dependency. They operate on plain attrsets
# and resource objects. Packages receive this as the `kix` argument.
#
# Usage:
#   service = self.deployment
#     |> kix.service.fromWorkload { name = "my-svc"; }
#     |> scope.mkResource;
#
#   ingress = self.service
#     |> kix.ingress.fromService { name = "my-ing"; host = "example.com"; }
#     |> clusterIssuer.out.withCert
#     |> scope.mkResource;
#
# Mount helpers:
#   libraryMount = kix.mount.pvc storage { mountPath = "/data"; };
#   configMount  = kix.mount.configMap self.configMap { mountPath = "/config"; };
#
#   deployment = { ... }
#     |> kix.withMounts [ self.libraryMount self.configMount ]
#     |> scope.mkDeployment;

{ lib }:

rec {

  # Shorthand for container port declaration.
  # Usage: port "http" 2283           → { name = "http"; containerPort = 2283; }
  #        port "dns" 53 // { protocol = "UDP"; }
  port = name: containerPort: { inherit name containerPort; };

  # Convert an attrset of env vars to the K8s [{ name, value }] list format.
  # Null values are filtered, so lib.optionalAttrs works naturally for conditionals.
  mkEnvVars = attrs:
    lib.mapAttrsToList (name: value: { inherit name value; })
      (lib.filterAttrs (_: v: v != null) attrs);

  # Parse a K8s resource quantity string to GiB (as a number).
  # Supports Ti, Gi, Mi suffixes. Returns null for unrecognized formats.
  # Strips Nix string context so it works on out.* values.
  parseGi = s:
    let
      str = builtins.unsafeDiscardStringContext (toString s);
      matchTi = builtins.match "([0-9]+)Ti" str;
      matchGi = builtins.match "([0-9]+)Gi" str;
      matchMi = builtins.match "([0-9]+)Mi" str;
    in
    if matchTi != null then (builtins.fromJSON (builtins.head matchTi)) * 1024
    else if matchGi != null then builtins.fromJSON (builtins.head matchGi)
    else if matchMi != null then (builtins.fromJSON (builtins.head matchMi)) / 1024
    else null;

  # --- Service helpers ---

  service = {
    # Extract service-compatible port entries from a workload resource.
    # Reads spec.template.spec.containers[*].ports from the workload's rawManifest.
    extractPorts = workload:
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
    #   - outputs.port from first container port
    #
    # Consumed config: name, type, ports
    # Passthrough to mkResource: outputs, requires, labels, annotations, extra, etc.
    fromWorkload =
      {
        name,
        type ? "ClusterIP",
        ports ? null,
        ...
      }@cfg:
      workload:
      let
        finalPorts = if ports != null then ports else service.extractPorts workload;
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
  };

  # --- Ingress helpers ---

  ingress = {
    # Create an Ingress attrset from a service resource.
    #
    # Auto-derives:
    #   - backend service name from service.out.name
    #   - backend port from service.out.port (override with `port`)
    #
    # Consumed config: name, host, path, pathType, port, className, tls
    # Passthrough to mkResource: annotations, labels, requires, extra, etc.
    fromService =
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
      svc:
      let
        servicePort =
          if port != null then port
          else if svc ? out.port then
            builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
          else
            throw "ingress.fromService: service '${svc.name or "unknown"}' has no out.port — specify port explicitly";
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
                    name = svc.out.name;
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
  };

  # --- Mount helpers ---
  # Typed constructors for volume mounts. Each returns a mount object
  # ({ _type, name, mountPath, source }) or null if the resource is null.
  # Name auto-derives from the resource's out.name.

  mount = {
    # PersistentVolumeClaim mount.
    pvc = resource: { mountPath, name ? null, readOnly ? false }:
      if resource == null then null
      else {
        _type = "kix-mount";
        name = if name != null then name
               else builtins.unsafeDiscardStringContext resource.out.name;
        inherit mountPath readOnly;
        source.persistentVolumeClaim.claimName = resource.out.name;
      };

    # ConfigMap mount.
    configMap = resource: { mountPath, name ? null }:
      if resource == null then null
      else {
        _type = "kix-mount";
        name = if name != null then name
               else builtins.unsafeDiscardStringContext resource.out.name;
        inherit mountPath;
        source.configMap.name = resource.out.name;
      };

    # Secret mount.
    secret = resource: { mountPath, name ? null }:
      if resource == null then null
      else {
        _type = "kix-mount";
        name = if name != null then name
               else builtins.unsafeDiscardStringContext resource.out.name;
        inherit mountPath;
        source.secret.secretName = resource.out.name;
      };

    # EmptyDir mount (no resource — name is required).
    emptyDir = { mountPath, name, medium ? null, sizeLimit ? null }: {
      _type = "kix-mount";
      inherit name mountPath;
      source.emptyDir = {}
        // lib.optionalAttrs (medium != null) { inherit medium; }
        // lib.optionalAttrs (sizeLimit != null) { inherit sizeLimit; };
    };
  };

  # Inject mounts into a Deployment/StatefulSet/DaemonSet attrset (pre-seal).
  # Adds volumes to spec.template.spec.volumes and volumeMounts to containers.
  # Nulls in the list are filtered. Single container: auto-inject.
  # Multiple containers: error (not yet supported).
  withMounts = mounts: attrs:
    let
      validMounts = builtins.filter (m: m != null) mounts;
      volumes = map (m: { inherit (m) name; } // m.source) validMounts;
      volumeMounts = map (m:
        { inherit (m) name mountPath; }
        // lib.optionalAttrs (m.readOnly or false) { readOnly = true; }
      ) validMounts;

      templateSpec = attrs.spec.template.spec or {};
      containers = templateSpec.containers or [];

      injectedContainers =
        if builtins.length containers == 1 then
          let c = builtins.head containers;
          in [ (c // { volumeMounts = (c.volumeMounts or []) ++ volumeMounts; }) ]
        else if containers == [] then containers
        else throw "withMounts: multiple containers — mount targeting not yet supported";
    in
    attrs // {
      spec = attrs.spec // {
        template = attrs.spec.template // {
          spec = templateSpec // {
            volumes = (templateSpec.volumes or []) ++ volumes;
            containers = injectedContainers;
          };
        };
      };
    };

}
