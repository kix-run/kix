        networkPolicy.platformIntents.metrics-agent = {
          scope = "clusterwide";
          targetNamespace = "observability";
          podSelector."app.kubernetes.io/name" = "metrics-agent";
          egress = [
            { to = "dns"; }
            {
              to = "world";
              ports = [
                {
                  port = 443;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };