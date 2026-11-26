# 2026-11-26 · `kix deploy --prune` · Prune runs only after a successful apply, so freeing capacity takes two deploys.

On a full two-node cluster, a definition that removed one package and added another could not finish: the new pods stayed `Pending` for lack of CPU, the apply timed out, and the prune that would have freed the CPU never ran. The user has to deploy the removal alone first, then the addition.
