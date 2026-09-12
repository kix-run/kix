      instances.tunnel-system.cloudflared = {
        package = packages.cloudflared;
        config = {
          image = "cloudflare/cloudflared:2026.9.0";
          tokenSource = ./cloudflare-token.enc.yaml;
          replicas = 2;
        };
      };