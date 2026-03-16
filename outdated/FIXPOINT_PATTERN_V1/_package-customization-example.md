# Custom CoreDNS based on default coredns deployment

**Goal:** replace the normal workload (deployment) with a statefulset

The following example BOTH
- replaces the actual workload reference - so anyone checking out coredns.workload will now get the statefulset
- but also the DAG hierarchy, the deployment and whatever it needed is not showing up in the generated manifests anymore

```
myCoredns = pkgs.coredns.overrideParts (self: super: {

  workload = k8s.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "coredns";
    namespace = "kube-system";
    requires = [ self.pdb ];       # ← still pulls PDB
    spec = {
      replicas = 3;
      serviceName = self.service.ref;   # ← NOW service is in closure too
      selector.matchLabels."k8s-app" = "kube-dns";
      template = {
        metadata.labels."k8s-app" = "kube-dns";
        spec = {
          # ↓ Same SA ref — pulls in the entire RBAC chain via requires
          serviceAccountName = self.serviceAccount.ref;
          containers = [{
            name = "coredns";
            image = "registry.k8s.io/coredns/coredns:v1.11.1";
            args = [ "-conf" "/etc/coredns/Corefile" ];
            volumeMounts = [
              { name = "config"; mountPath = "/etc/coredns"; readOnly = true; }
              { name = "data"; mountPath = "/var/coredns"; }
            ];
          }];
          volumes = [{
            name = "config";
            configMap.name = self.configmap.ref;   # ← same configmap
          }];
        };
      };
      volumeClaimTemplates = [{
        metadata.name = "data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "1Gi";
        };
      }];
    };
  };
});
```

New closure:
```
myCoredns.workload.closure:

  StatefulSet/coredns
  ├─ ref → ServiceAccount/coredns
  │        └─ requires → ClusterRoleBinding/system:coredns
  │                      ├─ ref → ClusterRole/system:coredns
  │                      └─ ref → ServiceAccount (seen)
  ├─ ref → ConfigMap/coredns
  ├─ ref → Service/kube-dns          ← NEW (serviceName ref)
  └─ requires → PDB/coredns

  = [ StatefulSet, SA, ConfigMap, Service, PDB,
      ClusterRoleBinding, ClusterRole ]
```

The Service appeared in the closure because the StatefulSet references it via `serviceName`. It *wasn't* in the Deployment closure because Deployments don't need a `serviceName`. The DAG reflects reality automatically.

## The mental model
```
             YAML ref direction        Semantic dep direction
             (what k8s sees)           (what our DAG models)

Binding ───ref──→ SA                   SA ───requires──→ Binding
Binding ───ref──→ Role                 Binding ───ref──→ Role (same)
Deploy  ───ref──→ SA                   Deploy ───ref──→ SA (same)
Deploy  ───ref──→ ConfigMap            Deploy ───ref──→ ConfigMap (same)
PDB     ──label─→ Deploy pods          Deploy ───requires──→ PDB

Rule: if A refs B, the dep is A → B (automatic).
      if A needs B but B refs A, then A.requires = [B] (manual).
