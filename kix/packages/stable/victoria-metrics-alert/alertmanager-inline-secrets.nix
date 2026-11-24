# Refuses credentials written inline in an Alertmanager configuration.
# `settings` lands in a Secret that Kix renders, so an inline value is
# stored in the Nix store and in the rendered manifests. Every key below is
# a secret in Alertmanager v0.33.1 and v0.35.0 (config/config.go, the
# integrations' configuration in config/notifiers.go up to v0.33.1 and in
# notify/<integration>/config.go from v0.35.0, and the http_config of
# prometheus/common) and, except sigv4's, has a `_file` twin that reads it
# from a mounted file instead. The victoria-metrics-alert package runs
# v0.33.1 and the alertmanager package runs v0.35.0, and both use this list.
#
# Returns `settings` unchanged, or fails listing every inline credential.
#
#   import ./alertmanager-inline-secrets.nix { inherit lib fail; } settings

{ lib, fail }:
settings:
let
  # Secret keys, wherever they appear, and what to write instead.
  secretKeys = lib.genAttrs [
    # global
    "smtp_auth_password"
    "smtp_auth_secret"
    "slack_api_url"
    "slack_app_token"
    "opsgenie_api_key"
    "wechat_api_secret"
    "victorops_api_key"
    "telegram_bot_token"
    "rocketchat_token"
    "rocketchat_token_id"
    "mattermost_webhook_url"
    # receivers
    "alert_source_token"
    "auth_password"
    "auth_secret"
    "service_key"
    "routing_key"
    "app_token"
    "api_secret"
    "api_key"
    "user_key"
    "token"
    "bot_token"
    "token_id"
    # Discord, Microsoft Teams, and Mattermost webhook URLs carry a token.
    "webhook_url"
    # http_config: basic_auth, authorization, oauth2, tls_config
    "password"
    "credentials"
    "client_secret"
    "bearer_token"
    "key"
  ] (k: "read it from a file with `${k}_file`");

  # Keys that are secrets only inside one integration.
  secretKeysIn = {
    # A Slack webhook URL carries its token.
    slack_configs.api_url = "read it from a file with `api_url_file`";
    sigv4.secret_key = "sigv4 has no file form: leave `access_key` and `secret_key` unset and Alertmanager takes the AWS default credentials (a web identity token, or the credentials file that `profile` names)";
  };

  # Return "<path>: <remedy>" entries for every inline secret under `v`.
  walk =
    path: parent: v:
    if builtins.isAttrs v then
      lib.concatLists (
        lib.mapAttrsToList (
          k: child:
          let
            here = "${path}.${k}";
            remedy = secretKeysIn.${parent}.${k} or secretKeys.${k} or null;
          in
          if remedy != null && builtins.isString child && child != "" then
            [ "${here} (${remedy})" ]
          else
            walk here k child
        ) v
      )
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: walk "${path}[${toString i}]" parent) v)
    else
      [ ];

  found = walk "settings" "" settings;
in
if found == [ ] then
  settings
else
  fail {
    option = "settings";
    message = "${lib.concatStringsSep ", " found} ${
      if builtins.length found == 1 then "holds a credential" else "hold credentials"
    } inline. settings lands in a Secret that Kix renders, so the value would sit in Kix's local store and the rendered manifests.";
    fix = "Put the value in a Secret, mount it through extraSpec.secrets = [ \"<name>\" ] (at /etc/alertmanager/secrets/<name>/<key>), and name that path in the `_file` key.";
  }
