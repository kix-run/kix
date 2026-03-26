# ingress.nix — build part: Ingress resource (conditional on ingressNginx DI dep).
{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
  ingressNginx ? null,
  clusterIssuer ? null,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;
  h = import ./helpers.nix {
    inherit
      name
      config
      lib
      kix
      scope
      postgres
      valkey
      ;
  };
  inherit (h)
    rName
    compName
    servicePort
    componentLabels
    ;

  # ── DI-driven ingress ──────────────────────────────────────────
  hasIngress = ingressNginx != null && config.ingress.hosts != [ ];
  hasTls = hasIngress && clusterIssuer != null;
in
{
  # ── Ingress (DI-driven) ────────────────────────────────────────
  # Created automatically when ingressNginx is injected and hosts are set.
  # TLS is auto-enabled when clusterIssuer is injected.
  ingress =
    if hasIngress then
      let
        resolveServiceName =
          svcName:
          if svcName == "backend" then
            self.backendService.out.name
          else if svcName == "frontend" && config.frontend.enabled then
            self.frontendService.out.name
          else if svcName == "caddy" && config.caddy.enabled then
            self.caddyService.out.name
          else
            svcName;

        resolveServicePort =
          svcName:
          if svcName == "backend" then
            servicePort
          else if svcName == "frontend" then
            config.frontend.port
          else if svcName == "caddy" then
            config.caddy.port
          else
            80;

        rules = map (host: {
          host = host.host;
          http.paths = map (pathCfg: {
            path = pathCfg.path;
            pathType = pathCfg.pathType or "Prefix";
            backend.service = {
              name = resolveServiceName pathCfg.service;
              port.number = pathCfg.port or (resolveServicePort pathCfg.service);
            };
          }) host.paths;
        }) config.ingress.hosts;

        autoTls = config.ingress.autoTls or true;
        tlsSpec =
          if config.ingress.tls != [ ] then
            config.ingress.tls
          else if autoTls then
            let
              hosts = map (h: h.host) config.ingress.hosts;
            in
            if hosts != [ ] then
              [
                {
                  secretName = "${rName}-tls";
                  inherit hosts;
                }
              ]
            else
              [ ]
          else
            [ ];
      in
      {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "${rName}-${compName}";
        labels = componentLabels "ingress";
        annotations = config.ingress.annotations;
        spec = {
          ingressClassName = ingressNginx.out.ingressClassName;
          inherit rules;
        }
        // lib.optionalAttrs (tlsSpec != [ ]) {
          tls = tlsSpec;
        };
      }
      |> (if hasTls then clusterIssuer.out.withCert else lib.id)
      |> scope.mkResource
    else
      null;
}
