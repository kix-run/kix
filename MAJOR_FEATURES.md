# Major features

# Content-addressing (every resource is a hash and depends on hashes)

### Motivation

> Core idea: every resource name is the hash of the yaml resource (the "content" part). Every reference to any other resource (name) should be via the hash (the "addressing" part)
> 
> 
> **Why this is cool in nix:** this is essentially "provable" dependency tracking. Not just "i need glibc", but "i need THIS EXACT glibc". Nix leverages this to make dependency conflicts a thing of the past. And enables weird new things like ephemeral shells - you can just say "I want this program in this shell now - nix you figure it out"
> 

### Use-cases

1. Drift detection
    1. most obviously - if we know the hash (the name of the resource), we can recompute it and detect drift - and contrast it with the evaluation generating this hash in the nix store
2. aReliable cluster-state
    1. aif we know what state worked together, we can guarantee we have it - no surprises (no weird "helm installed something else with a different env var and now my cluster is broken"
3. Graph view into the cluster
    1. Since we have content-**addressing**, we can see a full dependency tree of the resources. Not only great for garbage collection, but especially interesting for debugging and cluster reasoning
4. Rollback
    1. There is a root node that is hashed with a \*perfectly\* reproducible recipe. A rollback is nothing else than pointing the traffic or manifest to the previous hash. 2 and 3 together create this.
    2. The previous "version" you could even keep around running, or it is likely still cached in the nix store,
5. Trivial gitops
    1. Gitops is just evaluating the nix recipe, and when all is fully built, replace the "current" hash of the head node
6. Service meshes(?)
    1. We could define a list of “binds”. Which translate out of content adressing into the “public space” (what hash is what service
        
        ***thought:** so that barriers between different deployments of different teams can be resolved in the cluster runntime. Might not want this anyways and rather co-evaluate with an argo-type pull together. But this way something like the new gateway api that might be worked on by different teams could work (and assume + verify dependencies exist)*
        
7. Trivial Canary rollouts
    1. everything can run in any form in parallel (hashes) (importantly WHILE reusing the exact same subsystems that did not change => hash did not change = resource did not change
    2. an update to a service would only redeploy the service and can do so in a canary setting
8. Trivial wave rollouts
    1. Since we know the perfect dependency graph, knowing what to roll out in what order is trivial
9. pull request as its own (isolated) deployment
    1. a mix of 4 and 6 => we can have a PR safely reuse systems that dont change, everything else is different anyways
    2. touching data is fine, but worth a consideration of default behavior
10. Dynamic duplicate dependencies
    1. you can pull in whatever you need, even if it exists twice (like a second coredns) - deduplication is responsibility of consumer, not creator (e.g. reusing coredns)

> this might be REALLY weird, since updates to a resource will now NOT replace them, but launch side-by-side (different hash)
> 
> 
> => deployment strategies and the likes wont work anymore
> 
> this makes rolling updates kind of trivial & this is also kind of what flux and helm do (new release name)
> 

# Functional approach (purity)

> Core idea: every manifest generation FULLY and DETERMINISTICALLY depends on its inputs - which are recreatable. In other words this guarantees the output (manifest) only depends on its inputs and no outside influence. No env vars, no side effects through imperative edits or ansible playbooks. Only pure evaluation.
> 
> 
> **Why this is cool in nix:** this is what makes it possible to trust your dependencies. And make others trust your output. Building a rust app with nix, depends on the **recipe** (not binary) of rustc, which in turn depends on the **recipe** of llvm. Obviously they get cached and not rebuilt. But the artifact is bit-for-bit identically reproducible. A functional programming language (like nix) is ideal since it follows the same guarantees.
> 
1. Locked inputs - for everything / (partial) immunity to supply chain attacks
    1. first of all - we get a lockfile for free
    2. every other input (code, resources, extensions pulled in from another git) are locked as well
    3. even any old download will have to be saved alongside a download hash to guarantee you got again exactly the same input
    4. any files references will be hashed (by nix internally) to guarantee fidelity
2. Perfect composability / Nix scales from build system to an entire cluster
    1. "lego-blocks" of infra logic can be safely reused and composed.
    2. dependencies are recipes, not binaries or state
3. Offers vertical integration with the rest of the nix stack
    1. vertical integration with build pipelines (and their hashes)
    2. nix-snapshotter to skip docker entirely
4. Inline operators
    1. one of the inputs can simply be the current cluster state
    2. side effects that depend on cluster state (most operators) could be configured(!) this way
        1. permissions might be wild though - this would not be handled by RBAC

# Modular evaluation

> Core idea: Reconcile at build time. Reconcile all requirements of all modules into one consistent output - or FAIL at build time. Everything is a module (not just apps of apps) and exposes features/config switches. This allows a module of an app (like a helm chart) to request a new dns entry from the current dns provider - at build time. Or if X is on and Y is on Z should also be on.
> 
> 
> **Why this is cool in nix:** this is essentially "provable" dependency tracking. Not just "i need glibc", but "i need THIS EXACT glibc". Nix leverages this to make dependency conflicts a thing of the past. And enables weird new things like ephemeral shells - you can just say "I want this program in this shell now - nix you figure it out"
> 
1. Build-time debugging
    1. as discussed in core-idea.
2. Can enable “cluster features”
3. Modules can be imported from the internet
    1. e.g. CNCF could have k8s-packages as an entire module that makes it trivial to say `services.rook.enable = true;`
4. Potentially a "language" for defining cluster logic - platform engineering
    1. platform engineering is still a wild west of ansible playbooks, scripting, third party solutions, helm templates, …
5. Separation of (team) concerns
    1. Security and complicance, even infra operator, teams can push their logic (also with higher prio) on every other module, not only as pre- and post- processors, but as orthogonal requirements
6. A small thing like a chart can be built to adjust based on cluster features
    1. "if we have a prometheus, I will use it" => automagically - not because values.yaml was touched
    2. “wherever I run, I expect a dns entry for X” or “If this cluster uses prometheus, I will expose my endpoint unless told not to”
7. The true "just make it run" experience
    1. it reconciles against the platform or cluster features
    2. or pulls everything it needs in by itself
8. Maintainability
    1. instead of go templating, the nix module system has defaults, priorities, mkForce, hierachies, submodules etc
    2. => everything you need to completely wire up an entire linux distro without going insane
