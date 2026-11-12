+++
kind = "changed"
+++
The scorecard no longer has the `reliability.hasResourceLimits` and `reliability.hasResourceRequests` rules. `reliability.boundedResources` reports every container that they reported, so each container that has no resource settings got three warnings for one problem. A `ruleOverrides.byRule` entry for either removed rule now has no effect.
