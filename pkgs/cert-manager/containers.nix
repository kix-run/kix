# cert-manager container definitions.
#
# All containers use pipe composition: mkContainer |> withProbe.
# This is the standard pattern across all kixpkgs packages.
#
# Source Helm chart: jetstack/cert-manager (v1.19.4)

{
  lib,
  kixlib,
  kixlib',
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers) containerSecCtx podNamespaceEnv;
in
{
  # --- Controller container ---
  controller =
    kixlib'.pod.mkContainer {
      name = "cert-manager-controller";
      image = kixlib.imageRef cfg.image;
      imagePullPolicy = cfg.image.pullPolicy;
      args = [
        "--v=${toString cfg.logLevel}"
        "--cluster-resource-namespace=$(POD_NAMESPACE)"
        "--leader-election-namespace=${cfg.leaderElection.namespace}"
        "--acme-http01-solver-image=${kixlib.imageRef cfg.acmeSolverImage}"
        "--max-concurrent-challenges=${toString cfg.maxConcurrentChallenges}"
      ];
      ports = [
        {
          containerPort = 9402;
          protocol = "TCP";
          name = "http-metrics";
        }
        {
          containerPort = 9403;
          protocol = "TCP";
          name = "http-healthz";
        }
      ];
      securityContext = containerSecCtx;
      resources = cfg.resources;
      env = [ podNamespaceEnv ];
    }
    |> kixlib'.pod.withLivenessProbe {
      httpGet = {
        path = "/livez";
        port = "http-healthz";
        scheme = "HTTP";
      };
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 15;
      failureThreshold = 8;
      successThreshold = 1;
    };

  # --- Webhook container ---
  webhook =
    kixlib'.pod.mkContainer {
      name = "cert-manager-webhook";
      image = kixlib.imageRef cfg.webhook.image;
      imagePullPolicy = cfg.webhook.image.pullPolicy;
      args = [
        "--v=${toString cfg.logLevel}"
        "--secure-port=${toString cfg.webhook.securePort}"
        "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
        "--dynamic-serving-ca-secret-name=cert-manager-webhook-ca"
        "--dynamic-serving-dns-names=cert-manager-webhook"
        "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE)"
        "--dynamic-serving-dns-names=cert-manager-webhook.$(POD_NAMESPACE).svc"
      ];
      ports = [
        {
          containerPort = cfg.webhook.securePort;
          protocol = "TCP";
          name = "https";
        }
        {
          containerPort = 6080;
          protocol = "TCP";
          name = "healthcheck";
        }
        {
          containerPort = 9402;
          protocol = "TCP";
          name = "http-metrics";
        }
      ];
      securityContext = containerSecCtx;
      resources = cfg.webhook.resources;
      env = [ podNamespaceEnv ];
    }
    |> kixlib'.pod.withLivenessProbe {
      httpGet = {
        path = "/livez";
        port = "healthcheck";
        scheme = "HTTP";
      };
      initialDelaySeconds = 60;
      periodSeconds = 10;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    }
    |> kixlib'.pod.withReadinessProbe {
      httpGet = {
        path = "/healthz";
        port = "healthcheck";
        scheme = "HTTP";
      };
      initialDelaySeconds = 5;
      periodSeconds = 5;
      timeoutSeconds = 1;
      failureThreshold = 3;
      successThreshold = 1;
    };

  # --- CA Injector container ---
  cainjector = kixlib'.pod.mkContainer {
    name = "cert-manager-cainjector";
    image = kixlib.imageRef cfg.cainjector.image;
    imagePullPolicy = cfg.cainjector.image.pullPolicy;
    args = [
      "--v=${toString cfg.logLevel}"
      "--leader-election-namespace=${cfg.leaderElection.namespace}"
    ];
    ports = [
      {
        containerPort = 9402;
        protocol = "TCP";
        name = "http-metrics";
      }
    ];
    securityContext = containerSecCtx;
    resources = cfg.cainjector.resources;
    env = [ podNamespaceEnv ];
  };

  # --- Startup API check container ---
  startupapicheck = kixlib'.pod.mkContainer {
    name = "cert-manager-startupapicheck";
    image = kixlib.imageRef cfg.startupapicheck.image;
    imagePullPolicy = cfg.startupapicheck.image.pullPolicy;
    args = [
      "check"
      "api"
      "--wait=1m"
      "-v"
    ];
    securityContext = containerSecCtx;
    resources = cfg.startupapicheck.resources;
    env = [ podNamespaceEnv ];
  };
}
