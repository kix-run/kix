{ lib }:

let
  autoPlural = kind: lib.toLower kind + "s";
  autoSingular = kind: lib.toLower kind;
  autoListKind = kind: kind + "List";
in

rec {
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

  clusterScoped =
    attrs:
    attrs
    // {
      spec = attrs.spec // {
        scope = "Cluster";
      };
    };

  withVersion =
    version: attrs:
    attrs
    // {
      spec = attrs.spec // {
        versions = map (v: v // { name = version; }) attrs.spec.versions;
      };
    };

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

  withPrinterColumns =
    columns: attrs:
    attrs
    // {
      spec = attrs.spec // {
        versions = map (v: v // { additionalPrinterColumns = columns; }) attrs.spec.versions;
      };
    };

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

  withLabels =
    labels: attrs:
    attrs
    // {
      inherit labels;
    };

  withAnnotations =
    annotations: attrs:
    attrs
    // {
      annotations = (attrs.annotations or { }) // annotations;
    };
}
