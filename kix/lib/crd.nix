# CRD transforms — pipeable attrset transformers for building CRD specs.
#
# Transforms produce/consume the K8s-native CRD spec shape, so the result
# can be passed directly to scope.mkCRD.
#
# Usage:
#   crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
#   |> crd.withShortNames [ "sgclu" ]
#   |> scope.mkCRD
#
# For irregular names, override via deep merge in the second arg to fromKind:
#   crd.fromKind "SGDbOps" {
#     spec.group = "stackgres.io";
#     spec.names.plural = "sgdbops";
#   }

{ lib }:

let
  autoPlural = kind: lib.toLower kind + "s";
  autoSingular = kind: lib.toLower kind;
  autoListKind = kind: kind + "List";
in

rec {
  # Build a CRD spec from a kind. Auto-derives plural, singular, listKind.
  # Defaults: Namespaced, v1, permissive schema, status subresource.
  # The second argument is deep-merged, so any field can be overridden.
  fromKind =
    kind: extra:
    lib.recursiveUpdate {
      spec = {
        scope = "Namespaced";
        names = {
          inherit kind;
          listKind = autoListKind kind;
          plural = autoPlural kind;
          singular = autoSingular kind;
        };
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
            subresources.status = { };
            schema.openAPIV3Schema = {
              type = "object";
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                spec = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
                status = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
              };
            };
          }
        ];
      };
    } extra;

  # Set CRD scope to Cluster.
  clusterScoped =
    attrs:
    attrs
    // {
      spec = attrs.spec // {
        scope = "Cluster";
      };
    };

  # Override the version name on all versions.
  withVersion =
    version: attrs:
    attrs
    // {
      spec = attrs.spec // {
        versions = map (v: v // { name = version; }) attrs.spec.versions;
      };
    };

  # Add short names to spec.names.
  withShortNames =
    shortNames: attrs:
    attrs
    // {
      spec = attrs.spec // {
        names = attrs.spec.names // {
          inherit shortNames;
        };
      };
    };

  # Add categories to spec.names.
  withCategories =
    categories: attrs:
    attrs
    // {
      spec = attrs.spec // {
        names = attrs.spec.names // {
          inherit categories;
        };
      };
    };

  # Add printer columns to all versions.
  withPrinterColumns =
    columns: attrs:
    attrs
    // {
      spec = attrs.spec // {
        versions = map (v: v // { additionalPrinterColumns = columns; }) attrs.spec.versions;
      };
    };

  # Override the spec schema on all versions.
  withSchema =
    schema: attrs:
    attrs
    // {
      spec = attrs.spec // {
        versions = map (
          v:
          v
          // {
            schema.openAPIV3Schema = v.schema.openAPIV3Schema // {
              properties = v.schema.openAPIV3Schema.properties // {
                spec = schema;
              };
            };
          }
        ) attrs.spec.versions;
      };
    };

  # Set labels on the CRD resource itself (metadata.labels, not spec).
  withLabels =
    labels: attrs:
    attrs
    // {
      inherit labels;
    };
}
