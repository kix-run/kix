# Single source of truth for the kinds the Altinity operator serves.
# Consumed by crds.nix (the CRD resources) and operator.nix (the RBAC
# plurals), so the shipped CRDs and the operator's permissions cannot drift
# apart.
#
# All four ship, whether or not Kix has a builder for them. The operator
# lists ClickHouseOperatorConfigurations at startup, its metrics exporter
# runs an informer on them, and the reconciler merges
# ClickHouseInstallationTemplates into every installation. Whether 0.27.4
# survives one of them being absent is unproven, and the VictoriaMetrics
# operator's answer to the same question was a crashloop that took three
# minutes to show (victoria-metrics-operator/kinds.nix). Trim this table only
# with a live run that proves the operator tolerates it.
#
# `access` is what the upstream ClusterRole grants on the kind itself. The
# operator never creates its own custom resources, and it only reads the two
# kinds that configure it. `finalizers` and `status` grants are the same for
# every kind and live in operator.nix.
#
# `operand` marks the kinds the operator turns into pods. Those carry the
# readiness convention and the fact behavior in crds.nix, and get an out.mk*
# builder in default.nix.
let
  reconciled = [
    "get"
    "list"
    "watch"
    "patch"
    "update"
    "delete"
  ];
  readOnly = [
    "get"
    "list"
    "watch"
  ];
in
{
  crdDefs = {
    clickHouseInstallations = {
      kind = "ClickHouseInstallation";
      group = "clickhouse.altinity.com";
      plural = "clickhouseinstallations";
      shortNames = [ "chi" ];
      version = "v1";
      access = reconciled;
      operand = true;
      # The label the operator stamps on every pod of an installation.
      operandLabel = "clickhouse.altinity.com/chi";
    };
    clickHouseKeeperInstallations = {
      kind = "ClickHouseKeeperInstallation";
      group = "clickhouse-keeper.altinity.com";
      plural = "clickhousekeeperinstallations";
      shortNames = [ "chk" ];
      version = "v1";
      access = reconciled;
      operand = true;
      operandLabel = "clickhouse-keeper.altinity.com/chk";
    };
    clickHouseInstallationTemplates = {
      kind = "ClickHouseInstallationTemplate";
      group = "clickhouse.altinity.com";
      plural = "clickhouseinstallationtemplates";
      shortNames = [ "chit" ];
      version = "v1";
      access = readOnly;
      operand = false;
    };
    clickHouseOperatorConfigurations = {
      kind = "ClickHouseOperatorConfiguration";
      group = "clickhouse.altinity.com";
      plural = "clickhouseoperatorconfigurations";
      shortNames = [ "chopconf" ];
      version = "v1";
      access = readOnly;
      operand = false;
    };
  };
}
