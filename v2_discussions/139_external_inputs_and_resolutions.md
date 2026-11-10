# 139: External Inputs and Resolutions

**Status:** RFC
**Related:** `117_self_service_platform_interface.md` (the request half), `91_cicd_organizational_patterns.md` (§5 shift-left self-service), `45_multi_team_and_operator_models.md` (repo topology), `129a_grounding_field_and_prior_art.md` (pin coherence as the fleet-level computation), `archive/138_values_that_vary_per_deploy.md` (the design; implemented in #89)

---

## 1. Why this doc exists

Doc 138 shipped image pins. A pin file records what an image reference resolved to, `kix pin` writes it, and a cluster definition reads it.

The question that prompted this doc: a platform interface where a client requests a Postgres cluster looks like the same problem. Both are inputs that come from outside the compilation unit and have to appear in Git. Is the pin mechanism the general answer, and if not, what is?

The short answer is that they are two different things that often travel together. This doc names the difference, says which parts of doc 138 generalise, and says which parts should not.

## 2. The distinction

**A request is intent.** Somebody asks for a database with certain settings. Every value in the request is a value a person chose. It needs no lookup. It can be reviewed by reading it. Doc 117 already covers this shape: an instance file in the repository, a schema compiled from the package's module options, and a pull request as the approval mechanism.

**A resolution is a fact obtained at a moment in time.** An image digest, an allocated hostname or IP address, a cloud resource identifier, a storage class that has to exist on this cluster. Nobody chose the value. Something outside the repository was asked, and it answered.

The test for whether something is resolution-shaped is not "does it come from outside the repository". Almost everything does. The test is narrower:

> Could the outside source give a different answer tomorrow, and would that change what deploys without anybody noticing?

A container tag passes that test, which is why doc 138 exists. A replica count in a request does not. Nobody re-reads a replica count from a registry.

A Postgres request is therefore not pin-shaped. What is pin-shaped is the smaller set of things the request *implies but does not decide*. The request says "I want Postgres 16 with 50 GiB". The resolution says which image digest that turned out to be, which storage class was available, and which hostname was allocated.

## 3. What generalises from doc 138

Three parts carry over cheaply.

**The envelope.** Every resolution wants the same fields, and they are the fields a pin already has: what was asked for, what it resolved to, what source revision it was built from, who resolved it, and when. `sourceRev` is the one that earns its place in the least obvious way. It is what catches a resolution step that silently did not run, which is otherwise invisible because the deploy succeeds and the cluster runs old code.

**The check verb.** `kix pin check` asks whether every recorded value is still real, and it asks by digest rather than by tag, because the digest is the thing that breaks a deploy. The general form is the same: verify the recorded resolution against the source it came from, and separate "this is broken" from "this moved and nothing is broken".

**The receipt.** Doc 138 writes provenance into the Activation status on every deploy. A request-based platform wants exactly this, and wants a little more: which requests were in this build, and which resolutions were in force. That is also what a day-2 "what state is my request in" endpoint would read, which is doc 117 §5's assembly gap.

## 4. What should not generalise

**The resolver itself.** It is tempting to make `kix pin` into `kix resolve` with pluggable resolvers: a registry resolver, a DNS resolver, an IP address manager resolver, a cloud resolver. That would put arbitrary network calls at the point in the system where a wrong answer is hardest to see. A resolver decides what runs in production, and a plugin is code nobody reviewed on the day it mattered.

The alternative is to add resolvers one at a time, each as its own verb, each with its own refusals, and to keep the shared parts to the envelope and the check. Doc 138 confined the registry dependency to a single command for the same reason, and nothing resolves a tag during a deploy.

**A second file format.** Requests and resolutions are different things, but that does not mean they need different machinery. A resolution is data with a fixed small shape. A request is data validated against a schema compiled from module options. Both are files in the repository read at evaluation time.

## 5. A conflict between 117 and 138 worth naming

Doc 117 §3.4 says the request lifecycle is the pull request lifecycle: a request arrives as a file on a branch, CI compiles it, policy decides, the merge provisions it.

A resolution has a different lifecycle. It is written by a bot, usually after a build finished, and it must not trigger the build that produces the next resolution. That loop is structural, so the exclusion has to be structural too, which is why `kix pin check --workflows` exists.

If requests and resolutions share a directory, the two lifecycles collide. A resolution commit lands in a path a request workflow watches, and the build starts again. Two ways out, and this doc does not pick one:

- **Separate them by path.** Requests live under `instances/`, resolutions under a sibling directory, and the workflow filters name only the first. Simple, and it relies on a convention that a later well-meaning change can undo, which is what the trigger check is for.
- **Separate them by lane.** A resolution commit is made by an identity that the deploy workflow ignores, so the exclusion is about who wrote it rather than what path it touched. Stronger, and it needs a bot identity that can push to a protected branch, which is already an open item on the Lithus side.

## 6. A correction to doc 138, and what it changes here

Doc 138 argued that a pin file must be Nix rather than JSON, because the CLI's evaluation cache fingerprints `.nix` files and `flake.lock` and nothing else. That was true when the cache landed in `6fd83ae`, but `2a7e0ad` widened `walk_nix_files` (`cli/kix-core/src/eval/cache.rs`) to `.nix`, `.yaml`, `.yml` and `.json`. A JSON pin file would invalidate the cache correctly today.

This matters here because doc 117 §3.3 proposes JSON instance files. Had the original claim held, 117 would have had the same bug. It does not, so requests can be JSON, which is what an external portal or an agent can write without knowing Nix.

The remaining argument for Nix was narrower and specific to resolutions: a resolution file is written by a machine and read by a person, so the header explaining what it is and how to change it is load-bearing, and JSON has no comments. #89 answered that with a `note` field per entry, carried through every rewrite and never reaching a manifest, which puts the explanation next to the entry it explains rather than at the top of the file. JSON5 was considered and rejected, because `builtins.fromJSON` refuses it and only import-from-derivation could bridge the gap. TOML would have parsed comments and preserved them across rewrites, but it is not in the cache extension list, so choosing it would have made doc 138's false claim true.

JSON also let `kix pin` drop any Nix read at all, which serves the "works when evaluation is unhappy" property that doc 138 asked for and its own recommendation did not deliver.

Doc 138 is corrected and archived; the three decisions that changed are in `archive/138_values_that_vary_per_deploy.md` §0.

## 7. Open questions

1. **Where does a resolution attach?** A pin is keyed by a name the cluster definition chooses (`pins.get "web"`). A resolution belonging to a request is keyed by the request. Does it live inside the request file, next to it, or in one file per cluster? Inside is the most readable and makes the bot rewrite a file a human also edits, which is the case `--force` exists to refuse.

2. **Who resolves, and when?** For images, CI resolves after a build. For an allocated address or a cloud resource, resolution has a side effect: something is created. That is a materially different act from reading a digest, and it may not belong in the same verb, or in Kix at all.

3. **Does a request need a resolution before it can be reviewed?** If a reviewer approves a request and the resolution happens afterwards, the reviewer approved something incomplete. If resolution happens first, an unmerged request has already caused an allocation. Terraform's plan and apply split is the same problem, and its answer is that the plan is not binding.

4. **Fleet coherence.** Doc 129a names pin coherence as the one global computation a fleet layer would own. If resolutions generalise beyond images, that computation grows: is every cluster in the fleet running the resolution its request implies, and can they disagree on purpose? This is a fleet question, not a cluster question, and belongs with 129.

5. **What does the receipt owe a request?** Doc 138's receipt records inputs and images. A platform interface wants to ask "what happened to my request", which needs the receipt to carry request identity too. That overlaps doc 117 §5's catalog artifact, and the two should be designed together rather than twice.
