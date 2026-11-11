# filebrowser: the File Browser web file manager, serving the files on one
# volume.
#
# Installs a Deployment and a Service on port 80, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway.
#
# Dependencies:
#   storage (required)   a claim, mounted at /data. File Browser serves
#                        /data/files and keeps its user database in
#                        /data/database, so users survive restarts.
#   filebrowserUsers (optional)
#                        a secret whose keys are the names in `users` and
#                        whose values are their passwords, at least 12
#                        characters. A `secret` (SOPS source) restarts the
#                        pod when it changes.
#   an ingress controller or gateway, a cluster issuer (optional): read by
#                        `kix.expose` for the route and its TLS
#
# Minimal instance:
#
#   instances.files = {
#     storage = {
#       package = packages.persistent-volume-claim;
#       config.size = "10Gi";
#     };
#     filebrowser.package = packages.experimental.filebrowser;   # takes deps.storage
#   };
#
# Users: with `users` set, the sync-users init container creates or
# updates each listed user on every start: password from
# filebrowserUsers, `scope` (a folder under /data/files, created if
# missing), and permissions. Command execution is off for every user.
# Users removed from `users` stay in the database until deleted in the
# UI. Without `users`, File Browser creates an `admin` user with a random
# password on first start and prints it in the log.
#
#   instances.files.filebrowser = {
#     package = packages.experimental.filebrowser;
#     config.users = {
#       me.admin = true;
#       guest = {
#         scope = "/from-guest";
#         perm.share = false;
#       };
#     };
#   };
#   instances.files.filebrowser-users = {
#     package = packages.secret;
#     aliases = [ "filebrowserUsers" ];
#     config = {
#       source = ./secrets/filebrowser-users.yaml;
#       keys = [ "me" "guest" ];
#     };
#   };
#
# `out`: the Service's `name`, `fqdn`, and `port` (80).
#
# Escape hatches: `ingress` for the route's host and annotations, and the
# instance's `partsOverlays`.
#
# Limits: one replica, because the database is a single file.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "v2.63.18";
    description = "Filebrowser: web-based file manager";
    owner = "app-team";
  };

  options = {
    image = kix.options.image {
      repository = "filebrowser/filebrowser";
      tag = "v2.63.18";
      pullPolicy = null;
    };
    # Upstream publishes no chart or resource guidance. An idle instance
    # holds about 15 MiB; the limits leave room for archive downloads.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    };
    ingress = kix.options.ingress;
    users = lib.mkOption {
      default = { };
      description = "Users the sync-users init container creates or updates on every start. Each name is also a key of the filebrowserUsers secret, which holds its password.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            scope = lib.mkOption {
              type = lib.types.str;
              default = "/";
              description = "The user's root folder, relative to /data/files. The init container creates it.";
            };
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "File Browser's admin permission: manage users and settings.";
            };
            perm = lib.genAttrs [ "create" "delete" "download" "modify" "rename" "share" ] (
              p:
              lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "File Browser's ${p} permission inside the user's scope.";
              }
            );
          };
        }
      );
    };
    tokenExpirationTime = lib.mkOption {
      type = lib.types.str;
      default = "2h";
      description = "How long a login session lasts, as a Go duration. An upload still running when the session expires fails, so raise it for large files over slow links.";
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        storage,
        filebrowserUsers ? null,
        scope,
        kix,
        ...
      }:
      let
        who = "filebrowser ${scope.namespaceName}/${name}";
        userNames = builtins.attrNames config.users;
        usersSecret = kix.checkSecretKeys {
          inherit who;
          arg = "filebrowserUsers";
          dep =
            if userNames != [ ] && filebrowserUsers == null then
              throw "${who}: `users` lists ${lib.concatStringsSep ", " userNames}, and their passwords come from deps.filebrowserUsers, which is not wired. Add a secret instance with alias filebrowserUsers and one key per user."
            else
              filebrowserUsers;
          keys = userNames;
        };

        # The image's settings.json sets database and root; FB_* variables
        # take precedence over the config file.
        fbEnv = [
          {
            name = "FB_DATABASE";
            value = "/data/database/filebrowser.db";
          }
          {
            name = "FB_ROOT";
            value = "/data/files";
          }
        ];

        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 1000;
          readOnlyRootFilesystem = true;
        };

        passwordVar = i: "USER_PASSWORD_${toString i}";
        flag = n: v: "--${n}=${lib.boolToString v}";
        userFlags =
          u:
          lib.escapeShellArgs (
            [
              "--scope=${u.scope}"
              (flag "perm.admin" u.admin)
              (flag "perm.execute" false)
            ]
            ++ lib.mapAttrsToList (p: v: flag "perm.${p}" v) u.perm
          );
        syncUser =
          i: n:
          let
            u = config.users.${n};
            arg = lib.escapeShellArg n;
            password = "\"$" + passwordVar i + "\"";
          in
          ''
            mkdir -p /data/files/${lib.escapeShellArg (lib.removePrefix "/" u.scope)}
            if filebrowser users find ${arg} >/dev/null 2>&1; then
              filebrowser users update ${arg} --password=${password} ${userFlags u}
            else
              filebrowser users add ${arg} ${password} ${userFlags u}
            fi
          '';

        # `config init` writes the settings File Browser reads from its
        # database. The server takes its port, address and root from the
        # image's settings.json and the FB_* variables, but `users add`
        # resolves a scope against the root stored in the database, so
        # `config set` writes it there too.
        syncUsersContainer = {
          name = "sync-users";
          image = kix.image.ref config.image;
          inherit securityContext;
          resources = config.resources;
          env =
            fbEnv
            ++ kix.mkEnvVars (
              lib.listToAttrs (
                lib.imap0 (i: n: lib.nameValuePair (passwordVar i) (usersSecret.out.keyRef n)) userNames
              )
            );
          command = [
            "sh"
            "-ec"
            (
              ''
                mkdir -p /data/files /data/database
                if [ ! -f "$FB_DATABASE" ]; then
                  filebrowser config init
                fi
                filebrowser config set --disableExec --root="$FB_ROOT" \
                  --tokenExpirationTime=${lib.escapeShellArg config.tokenExpirationTime}
              ''
              + lib.concatStrings (lib.imap0 syncUser userNames)
            )
          ];
          volumeMounts = [
            {
              name = storage.out.name;
              mountPath = "/data";
            }
            {
              name = "tmp";
              mountPath = "/tmp";
            }
          ];
        }
        // lib.optionalAttrs (config.image.pullPolicy != null) {
          imagePullPolicy = config.image.pullPolicy;
        };
      in
      {
        deployment =
          {
            name = name;
            spec = {
              replicas = 1;
              # The database is a bolt file that one process locks; a
              # rolling update's second pod times out waiting for it.
              strategy.type = "Recreate";
              selector.matchLabels = scope.selectorLabels;
              # Kubernetes default: filebrowser documents no shutdown drain.
              template.spec.terminationGracePeriodSeconds = 30;
              template.spec.initContainers = lib.optional (userNames != [ ]) syncUsersContainer;
              template.spec.containers = [
                (
                  {
                    name = "filebrowser";
                    image = kix.image.ref config.image;
                    # The image's own user is uid 1000; stated so the kubelet
                    # can verify it rather than trust the image.
                    inherit securityContext;
                    env = fbEnv;
                    resources = config.resources;
                    ports = [
                      {
                        name = "http";
                        containerPort = 80;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                      periodSeconds = 30;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                    };
                  }
                  // lib.optionalAttrs (config.image.pullPolicy != null) {
                    imagePullPolicy = config.image.pullPolicy;
                  }
                )
              ];
            };
          }
          |> kix.withMounts [
            (kix.mount.pvc storage { mountPath = "/data"; })
            # The image's /init.sh copies settings.json into /config on
            # start.
            (kix.mount.emptyDir {
              name = "config";
              mountPath = "/config";
            })
            (kix.mount.emptyDir {
              name = "tmp";
              mountPath = "/tmp";
            })
          ]
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
