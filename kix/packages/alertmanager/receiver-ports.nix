# The TCP ports an Alertmanager configuration dials to deliver
# notifications, sorted and without duplicates.
#
# Each integration reads its address from the keys in `integrations`, in
# that order: the receiver's own keys, then `global`'s. The first key that
# is set decides the port: the port in a literal URL (443 or 80 by scheme
# when it has none), or 443 for a `_file` key, whose contents Kix cannot
# read. With none set, the port of Alertmanager's built-in address is used.
# Other keys ending in `_url` (Slack's `icon_url`, PagerDuty's `client_url`,
# Pushover's `url`) are links placed in the message and are not read.
#
# Throws, naming the receiver, on an integration this table does not know,
# on a dialled URL whose port it cannot read, and on a receiver that
# Alertmanager refuses for want of an address or a smarthost.
#
#   import ./receiver-ports.nix { inherit lib who; } settings

{ lib, who }:
settings:
let
  global = settings.global or { };

  # Keys and defaults from config/config.go and config/notifiers.go of
  # Alertmanager v0.33.1 (`Config.UnmarshalYAML` fills receivers from
  # `global`). `default = null`: Alertmanager has no built-in address and
  # refuses the receiver.
  integrations = {
    discord_configs = {
      keys = [
        "webhook_url"
        "webhook_url_file"
      ];
      default = null;
    };
    incidentio_configs = {
      keys = [
        "url"
        "url_file"
      ];
      default = null;
    };
    jira_configs = {
      keys = [ "api_url" ];
      global = [ "jira_api_url" ];
      default = null;
    };
    mattermost_configs = {
      keys = [
        "webhook_url"
        "webhook_url_file"
      ];
      global = [
        "mattermost_webhook_url"
        "mattermost_webhook_url_file"
      ];
      default = null;
    };
    msteams_configs = {
      keys = [
        "webhook_url"
        "webhook_url_file"
      ];
      default = null;
    };
    msteamsv2_configs = {
      keys = [
        "webhook_url"
        "webhook_url_file"
      ];
      default = null;
    };
    opsgenie_configs = {
      keys = [ "api_url" ];
      global = [ "opsgenie_api_url" ];
    };
    pagerduty_configs = {
      keys = [ "url" ];
      global = [ "pagerduty_url" ];
    };
    # Pushover posts to api.pushover.net; its `url` is a link in the message.
    pushover_configs.keys = [ ];
    rocketchat_configs = {
      keys = [ "api_url" ];
      global = [ "rocketchat_api_url" ];
    };
    # `app_url` (default https://slack.com/api/chat.postMessage) is dialled
    # with an app token, `api_url` with a webhook.
    slack_configs = {
      keys = [
        "api_url"
        "api_url_file"
        "app_url"
      ];
      global = [
        "slack_api_url"
        "slack_api_url_file"
        "slack_app_url"
      ];
    };
    # Without `api_url`, the regional AWS endpoint.
    sns_configs.keys = [ "api_url" ];
    telegram_configs = {
      keys = [ "api_url" ];
      global = [ "telegram_api_url" ];
    };
    victorops_configs = {
      keys = [ "api_url" ];
      global = [ "victorops_api_url" ];
    };
    webex_configs = {
      keys = [ "api_url" ];
      global = [ "webex_api_url" ];
    };
    webhook_configs = {
      keys = [
        "url"
        "url_file"
      ];
      default = null;
    };
    wechat_configs = {
      keys = [ "api_url" ];
      global = [ "wechat_api_url" ];
    };
  };

  portOfUrl =
    where: url:
    let
      m = builtins.match "([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)([/?#].*)?" url;
      scheme = lib.toLower (builtins.elemAt m 0);
      authority = builtins.elemAt m 1;
      port = builtins.match ".*:([0-9]+)" authority;
    in
    if !(builtins.isString url) || m == null || lib.hasInfix "{{" authority then
      throw "${who}: ${where} is ${builtins.toJSON url}, and Kix cannot read the port Alertmanager dials from it. Write the scheme, host, and port literally (https://host[:port]/path), or use the key's `_file` form where the integration has one, for which the egress policy opens port 443."
    else if port != null then
      lib.toInt (builtins.head port)
    else if scheme == "http" then
      80
    else
      443;

  portOfSmarthost =
    where: smarthost:
    let
      m = builtins.match ".*:([0-9]+)" smarthost;
    in
    if m == null then
      throw "${who}: ${where} is \"${smarthost}\", which has no port. Write it as host:port."
    else
      lib.toInt (builtins.head m);

  # The port of the first key set in `attrs`, or null.
  firstPort =
    whereOf: attrs: keys:
    let
      key = lib.findFirst (k: (attrs.${k} or null) != null) null keys;
    in
    if key == null then
      null
    else if lib.hasSuffix "_file" key then
      443
    else
      portOfUrl (whereOf key) attrs.${key};

  configPorts =
    receiver: type: i: entry:
    let
      where = "settings.receivers \"${receiver.name or "?"}\" ${type}[${toString i}]";
      integration =
        integrations.${type}
          or (throw "${who}: ${where}: Alertmanager has no integration `${type}`, so it refuses the configuration. The integrations are ${
            lib.concatStringsSep ", " (
              lib.sort builtins.lessThan (builtins.attrNames integrations ++ [ "email_configs" ])
            )
          }.");
      globalKeys = integration.global or [ ];
      fromEntry = firstPort (k: "${where}.${k}") entry integration.keys;
      fromGlobal = firstPort (k: "settings.global.${k}") global globalKeys;
      fallback = integration.default or 443;
      sources = lib.concatStringsSep " or " (
        integration.keys ++ map (k: "settings.global.${k}") globalKeys
      );
    in
    if type == "email_configs" then
      let
        smarthost = entry.smarthost or global.smtp_smarthost or null;
      in
      if smarthost == null then
        throw "${who}: ${where} has no smarthost and settings.global.smtp_smarthost is unset, so Alertmanager refuses the configuration. Set one of them to host:port."
      else
        [ (portOfSmarthost "${where}.smarthost" smarthost) ]
    else if fromEntry != null then
      [ fromEntry ]
    else if fromGlobal != null then
      [ fromGlobal ]
    else if fallback != null then
      [ fallback ]
    else
      throw "${who}: ${where} sets none of ${sources}, so Alertmanager refuses the configuration. Set one of them.";

  receiverConfigPorts =
    receiver:
    lib.concatLists (
      lib.mapAttrsToList (
        type: entries:
        lib.optionals (lib.hasSuffix "_configs" type && builtins.isList entries) (
          lib.concatLists (lib.imap0 (configPorts receiver type) entries)
        )
      ) receiver
    );
in
lib.unique (
  lib.sort builtins.lessThan (lib.concatMap receiverConfigPorts (settings.receivers or [ ]))
)
