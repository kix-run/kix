# The TCP ports an Alertmanager configuration dials to deliver
# notifications: the port in each receiver URL (443 or 80 by scheme when the
# URL has none, 443 when the URL comes from a file or Alertmanager's
# default), and the port of each email smarthost. Sorted and without
# duplicates. Throws, naming the receiver, on a URL or smarthost it cannot
# read and on an email receiver with no smarthost.
#
#   import ./receiver-ports.nix { inherit lib who; } settings

{ lib, who }:
settings:
let
  global = settings.global or { };
  portOfUrl =
    where: url:
    let
      m = builtins.match "([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)([/?#].*)?" url;
      scheme = lib.toLower (builtins.elemAt m 0);
      port = builtins.match ".*:([0-9]+)" (builtins.elemAt m 1);
    in
    if m == null then
      throw "${who}: ${where} is \"${url}\", which is not a URL Alertmanager can call. Write it as https://host[:port]/path."
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
  isUrlKey = k: k == "url" || lib.hasSuffix "_url" k;
  configPorts =
    receiver: type: i: entry:
    let
      where = "settings.receivers \"${receiver.name or "?"}\" ${type}[${toString i}]";
      urls = lib.filterAttrs (k: v: isUrlKey k && builtins.isString v) entry;
      globalUrl = global."${lib.removeSuffix "_configs" type}_api_url" or null;
    in
    if type == "email_configs" then
      let
        smarthost = entry.smarthost or global.smtp_smarthost or null;
      in
      if smarthost == null then
        throw "${who}: ${where} has no smarthost and settings.global.smtp_smarthost is unset, so Alertmanager refuses the configuration. Set one of them to host:port."
      else
        [ (portOfSmarthost "${where}.smarthost" smarthost) ]
    else if urls != { } then
      lib.mapAttrsToList (k: portOfUrl "${where}.${k}") urls
    else if builtins.isString globalUrl then
      [ (portOfUrl "settings.global.${lib.removeSuffix "_configs" type}_api_url" globalUrl) ]
    else
      [ 443 ];
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
