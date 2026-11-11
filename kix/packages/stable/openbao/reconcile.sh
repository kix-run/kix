#!/bin/sh
# Applies the declared policies, Kubernetes auth roles, and secrets engines
# to OpenBao, logged in through the role that self-initialization bound to
# this Job's ServiceAccount. It creates and updates; it deletes nothing, and
# lists the policies and roles OpenBao holds that are not declared.
#
# Inputs, from the ConfigMap mounted at $PWD:
#   reconcile.hcl            this Job's own policy
#   policies.txt, policy.<name>.hcl
#   roles.txt, role.<name>.json
#   mounts.txt               "<index> <path> <type>" per line, mount.<index>.json
set -eu

BAO_TOKEN=$(bao write -field=token auth/kubernetes/login \
  role="$RECONCILE_ROLE" jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
export BAO_TOKEN

# Its own policy first: it grants the secrets engine paths declared now,
# which may differ from those self-initialization wrote.
bao policy write "$RECONCILE_ROLE" reconcile.hcl

while read -r name; do
  [ -n "$name" ] || continue
  bao policy write "$name" "policy.$name.hcl"
done < policies.txt

while read -r name; do
  [ -n "$name" ] || continue
  bao write "auth/kubernetes/role/$name" "@role.$name.json"
done < roles.txt

while read -r index path type; do
  [ -n "$index" ] || continue
  if existing=$(bao read -field=type "sys/mounts/$path" 2>/dev/null); then
    if [ "$existing" != "$type" ]; then
      echo "reconcile: secrets engine $path is of type $existing in OpenBao and declared as $type; move or disable it in OpenBao, or change secretsEngines.\"$path\".type" >&2
      exit 1
    fi
    echo "reconcile: secrets engine $path exists ($type); its options are not changed"
  else
    bao write "sys/mounts/$path" "@mount.$index.json"
  fi
done < mounts.txt

# Drift: what OpenBao holds beyond the declaration. A failed listing is
# reported and does not fail the Job.
declared_policies=" root default $RECONCILE_ROLE $(tr '\n' ' ' < policies.txt) "
if policies=$(bao policy list); then
  for p in $policies; do
    case "$declared_policies" in
      *" $p "*) ;;
      *) echo "reconcile: policy $p exists in OpenBao and is not declared; this Job does not delete it" ;;
    esac
  done
else
  echo "reconcile: could not list policies" >&2
fi

declared_roles=" $RECONCILE_ROLE $(tr '\n' ' ' < roles.txt) "
if roles=$(bao list -format=json auth/kubernetes/role | tr -d '[]",'); then
  for r in $roles; do
    case "$declared_roles" in
      *" $r "*) ;;
      *) echo "reconcile: Kubernetes auth role $r exists in OpenBao and is not declared; this Job does not delete it" ;;
    esac
  done
else
  echo "reconcile: could not list Kubernetes auth roles" >&2
fi
