+++
kind = "note"
packages = ["experimental/infisical-operator"]
+++
`experimental/infisical-operator` runs Infisical operator 0.11.18 instead of 0.11.10. The deploy adds the `InfisicalStaticSecretPush` CRD, and the operator needs it to start, so the first deploy applies it before the operator runs. The operator's 401 and 403 errors now include the response body from Infisical. No action is needed.
