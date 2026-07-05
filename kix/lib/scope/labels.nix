{
  mkScopeLabels =
    {
      instanceName,
      labelStyle,
      selectorLabelsOverride,
    }:
    let
      selectorLabels =
        if selectorLabelsOverride != null then
          selectorLabelsOverride
        else if labelStyle == "helm" then
          {
            app = instanceName;
            release = instanceName;
          }
        else
          {
            "app.kubernetes.io/name" = instanceName;
            "app.kubernetes.io/instance" = instanceName;
          };

      instanceLabels =
        if labelStyle == "helm" then
          {
            release = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          }
        else
          {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };
    in
    {
      inherit selectorLabels instanceLabels;
      labels = {
        selector = selectorLabels;
        common = selectorLabels // instanceLabels;
        clusterScoped = {
          "app.kubernetes.io/name" = instanceName;
          "app.kubernetes.io/managed-by" = "kix";
        };
      };
    };
}
