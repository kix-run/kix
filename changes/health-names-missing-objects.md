+++
kind = "fixed"
+++
`kix health` now gives the right name and namespace for a missing object
whose namespace has a `-` in it. It showed
`Service/system-cnpg-webhook-service@cnpg` for the Service
`cnpg-webhook-service` in the namespace `cnpg-system`.
