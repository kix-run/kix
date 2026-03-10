# CoreDNS container definitions.
#
# All containers use pipe composition: mkContainer |> withVolumeMount |> withProbe.
# This is the standard pattern across all kixpkgs packages.

{
  lib,
  kixlib,
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers) kixlibCoredns ports;
in
{
  # --- Main CoreDNS container ---
  coredns =
    kixlibCoredns.pod.mkContainer {
      name = "coredns";
      image = kixlib.imageRef cfg.image;
      imagePullPolicy = cfg.image.pullPolicy;
      args = [
        "-conf"
        "/etc/coredns/Corefile"
      ];
      resources = cfg.resources;
      ports = ports.containerPorts;
      securityContext = cfg.securityContext;
    }
    |> kixlibCoredns.pod.withVolumeMount {
      name = "config-volume";
      mountPath = "/etc/coredns";
    }
    |> (
      c:
      if cfg.livenessProbe.enabled then
        kixlibCoredns.pod.withLivenessProbe {
          httpGet = {
            path = "/health";
            port = 8080;
            scheme = "HTTP";
          };
          inherit (cfg.livenessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        } c
      else
        c
    )
    |> (
      c:
      if cfg.readinessProbe.enabled then
        kixlibCoredns.pod.withReadinessProbe {
          httpGet = {
            path = "/ready";
            port = 8181;
            scheme = "HTTP";
          };
          inherit (cfg.readinessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        } c
      else
        c
    );

  # --- Cluster-proportional autoscaler container ---
  autoscaler =
    autoscalerKixlib:
    autoscalerKixlib.pod.mkContainer {
      name = "autoscaler";
      image = kixlib.imageRef cfg.autoscaler.image;
      imagePullPolicy = cfg.autoscaler.image.pullPolicy;
      resources = cfg.autoscaler.resources;
      command = [
        "/cluster-proportional-autoscaler"
        "--namespace=${cfg.namespace}"
        "--configmap=coredns-autoscaler"
        "--target=Deployment/coredns"
        "--logtostderr=true"
        "--v=2"
      ];
    }
    |> autoscalerKixlib.pod.withLivenessProbe {
      httpGet = {
        path = "/healthz";
        port = 8080;
        scheme = "HTTP";
      };
      initialDelaySeconds = 10;
      periodSeconds = 5;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 3;
    };
}
