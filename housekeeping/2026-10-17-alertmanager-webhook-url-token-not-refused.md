# 2026-10-17 · `kix/packages/alertmanager/inline-secrets.nix` · A `webhook_configs[].url` with an embedded token is not refused as an inline credential.

Alertmanager marks `webhook_configs[].url` as a secret and offers `url_file`, but `inline-secrets.nix` refuses only `webhook_url` and `slack_configs[].api_url`. A Discord or Mattermost URL written under `webhook_configs` keeps its token in the rendered Secret, and a cluster that lists `configuration` in `cluster.secrets.accept` takes the package's word that none is there.

The key is not refused because `receiver-ports.nix` reads the URL to derive the Alertmanager pods' world egress ports, and the usual value is an internal receiver (`http://alerts.ops.svc:8080/alert`) with no token; `url_file` would hide the port from the derivation. A fix needs a rule for which webhook URLs carry a token (a non-empty userinfo or query string, a known host such as `discord.com/api/webhooks`) and a way for a refused URL to still name its port.
