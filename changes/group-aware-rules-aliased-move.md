+++
kind = "error"
id = "K8031"
+++
`kix plan` and `kix deploy` refuse a build that moves an object between two API groups that Kubernetes serves as the same stored object, such as core `v1` `Event` and `events.k8s.io` `Event`, because the deploy would delete through the old group the object it just wrote through the new one. Keep the object's `apiVersion`, or deploy a build without the object first and then a build with it in the new group.
