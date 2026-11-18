+++
kind = "silent"
packages = ["experimental/keycloak"]
touches-data = true
+++
`keycloak` moves from 26.8.0 to 26.8.2, a patch release with security fixes. Some changes need action. Clients and service accounts that call the Admin REST API need the `kc-admin-api` client scope, or their tokens get a 401. Dynamic client registration can no longer set default roles or full scope, and it adds protocol mappers only for the types the realm settings allow. Remove the `Default Roles Disabled` and `Full Scope Disabled` client registration policies to restore the old behavior. Realms with StartTLS enabled on SMTP now fail to send mail when the server does not support StartTLS. The first start migrates every realm, and the upgrade stops the running pod before the new one starts, so Keycloak is unavailable until the new pod is ready. Upstream describes no way back to 26.8.0, so restore a database backup taken before the upgrade if you need to go back.
