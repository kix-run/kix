# The Alertmanager configuration the alertmanager and victoria-metrics-alert
# packages render when an instance sets no `settings`. It routes every
# alert, Watchdog included, to a receiver that drops it.
{
  global.resolve_timeout = "5m";
  route = {
    group_by = [
      "namespace"
      "alertname"
    ];
    group_wait = "30s";
    group_interval = "5m";
    repeat_interval = "12h";
    receiver = "null";
    routes = [
      {
        receiver = "null";
        matchers = [ "alertname = Watchdog" ];
      }
    ];
  };
  receivers = [ { name = "null"; } ];
}
