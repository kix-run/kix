+++
kind = "error"
id = "K5636"
+++
When two Kix clusters on one Kubernetes cluster deploy the same object and set a field to different values, the deploy of the second one now stops with `[K5636]`. The error names the object, the other Kix cluster, and the fields it owns. Earlier versions applied both, and the last deploy won without a message. Make the two cluster definitions agree on the object, or stop deploying it from all but one of them. `--force-conflicts` takes the fields for the Kix cluster you deploy, and the other Kix cluster's next deploy then stops in the same way. When a Kix cluster stops deploying an object that another Kix cluster still deploys, it now gives up its fields on that object, so the remaining Kix cluster owns them and can delete the object once it stops deploying it too.
