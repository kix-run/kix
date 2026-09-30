# 154: Website redesign, interview record

**Status:** Reference
**Type:** Interview record
**Related:** `business_discussions/52_website_brief.md` (the brief written from these answers)

## Context

On 2026-09-30 Adam asked Claude to act as a marketing consultant for a full redesign of the Kix website, starting from the story and the benefits rather than the current site. Claude read `docs-legacy/` (feature catalog, best practices, handbook) and proposed five themes, then asked the questions below. This document records the questions and Adam's answers so that later work on the website can check the brief against what was actually said.

Answers are Adam's words, lightly edited for dictation errors. Anything in square brackets is an editorial note.

## Adam's opening story

We are sick and tired of more and more layers of YAML. Every time we have a problem with Kubernetes, we seem as a community to try and add another layer of YAML on top to try and solve it. I get it, but we've now gone a few layers of YAML too deep, and it is time for a change.

Because we're going to break out of YAML, we decided to do something that really helps address the modern problems we're having with Kubernetes. We've seen projects try to let you use Python or procedural languages to create and manage Kubernetes resources, but it never felt quite right to us, although we could understand the motivation and what people wanted. Part of the problem was using procedural languages and not something functional. Functional languages are a bit hard for a lot of people to understand, but priorities have changed: something that can give fast feedback to AI is more important than something that humans enjoy writing.

## Round 1: themes

Claude proposed five themes extracted from the legacy docs:

1. Kix understands how your cluster fits together (the dependency graph, from which wiring, ordering, network policy, RBAC and monitoring are derived).
2. Mistakes surface before deploy, not in production (constructions that make mistakes impossible, eval-time errors, the scorecard).
3. Know what will happen before you change Kubernetes (diff, plan, ordered deploys, rollback, drift, GC).
4. The cluster is an artifact you can verify (reproducible builds, image pins, deploy receipts, attestations).
5. Write it once, run it on any cluster (DI, flavors, availability levels, one contract with several implementations).

Claude's notes: theme 1 is the root the others grow from; AI is better used as the "why now" than as a sixth theme; "standard Kubernetes underneath" and the Helm bridge are reassurances rather than themes; the legacy docs describe mechanisms rather than outcomes.

**Q: Where next: pick the primary buyer, or shape the YAML story?**

A: These all sound good. Number four is a bit abstract; it would be nice to make it more concrete. I also want to be able to string all of these together with the story we're telling.

## Round 2: questions for the brief

Claude proposed making theme 4 concrete through the moments it answers (an incident, an audit, a release, a rollback) and then asked the following.

### Audience

**Q1. Who is the primary reader, and is the person who pays the same as the person who uses it?**

A: A fairly general reader: anyone who uses Kubernetes day to day. We may ultimately need landing pages for specific kinds of reader, but for now it is the average Kubernetes, Hacker News reader. Someone who might be at a CNCF conference, KubeCon, that kind of thing.

**Q2. What does their stack look like today?**

A: Already Kubernetes, Argo, Helm, that kind of thing. Maybe they have to do compliance work. But this also makes life easier for people who are learning Kubernetes and want to interact with it through an agent.

**Q3. How far do we assume the reader already works with AI agents?**

A: Assume essentially everyone works with AI agents, but not everyone is comfortable with the results. Everyone knows AI is a thing, but there will be different levels of comfort about using it on infrastructure.

### The story

**Q4. What was the moment you personally got fed up?**

A: I got fed up with procedurally applying YAML with Ansible, which isn't something I'm particularly proud of as a way of managing Kubernetes. It happened before Argo. When I looked at Argo and Flux as the upgrade path, they didn't seem compelling at all. Adding more YAML on top never seemed like the right choice to me. I know Ansible is written in YAML too, but you have quite a lot of flexibility with it, which I appreciated.

**Q5. Which tools did you try, and do we name them on the site?**

A: Let's not name tools. Everyone feels their own pain.

**Q6. How visible should Nix be? Do users write Nix? Is the answer to "functional is hard" that the agent writes it and you review the plan?**

A: Downplay the Nix angle. We may need a section on why we use the Nix language, and that section can give some relatable reasons. Essentially, a functional language lets us do the foundational things that give us all the features on the page.

**Q7. Do you have a real war story for each theme?**

A: No war stories yet, but we can give examples everyone will appreciate easily, particularly by looking at the Kix packages, what they do, what they check, and what the Kix framework makes impossible.

### The offer

**Q8. What should a visitor do at the end, and does pricing appear?**

A: Write the site as though Kix is already open source. The action is try it now, install it now, read the docs. It is the Kix CLI that needs installing.

[Editorial note: `CLAUDE.prose.md` currently says the CLI is proprietary and closed source and that copy must not imply otherwise. The brief keeps an open-source-style call to action without claiming a licence, and flags this for a decision.]

**Q9. What proof do we have?**

A: We can show a picture of ourselves, the authors: Luca and Adam, with our pictures and where we work. We don't have quotes from other people yet, but expect to soon.

**Q10. How does Kix relate to GitOps tools like Argo CD and Flux?**

A: Kix is a replacement for Argo CD and Flux. It can still operate in a GitOps fashion. The Kix operator is still a work in progress, but Kix can be integrated into any CI pipeline, and the CI system uses the Kix CLI to deploy.

### Brand and scope

**Q11. Are the locked lines ("Kix is a Kubernetes compiler", "If it compiles, it will deploy safely", "verifiable cluster artifact") still fixed?**

A: When talking to people, "we're making a Kubernetes compiler" always gets them interested, so the H1 is fixed. Everything else is not fixed at all.

**Q12. How spicy should the tone be?**

A: Irreverent, likely, but not too spicy. Engineers are very sensitive to absolutes that are not absolute, and to overpromising. If you state clearly what it does, they will be receptive. That doesn't mean a section titled "What Kix is not for"; just state clearly what Kix can do and don't claim things it can't. We're infrastructure; we're responsible people.

**Q13. Which pages are in scope, and which sites do you admire?**

A: Not sure about pages for now. The main deliverable is a detailed briefing doc for the website creation process. That process will be design oriented, so it needs the main points to hit, the language to use, the tone of voice and the writing style.

**Q14. What will the design agent build with, and what should come back?**

A: [Covered by Q13: the output of this round is the brief. Framework and page list were left open.]

## Mid-session request

Adam asked for this separate record of the questions and answers in `v2_discussions/`, alongside the brief itself.
