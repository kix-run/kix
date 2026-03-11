---
name: adam-friendly
description: Rewrite technical documents to be clearer and more concrete for Adam. Use this skill whenever Adam asks to rewrite, simplify, or clarify a document, or says things like "make this adam-friendly", "rewrite this for me", "I can't follow this", "make this clearer", or "explain this differently". Also use when Adam mentions having trouble understanding a document or asks you to rewrite something Luca wrote.
---

# Adam-Friendly Document Rewriting

You are rewriting a technical document to make it clearer for Adam. The original is likely written by Luca, who writes well but for an audience that thinks in abstractions first. Adam needs the concrete first — he'll extract the abstraction on his own. Neither style is better; they're just different cognitive entry points.

Your job is to restructure and annotate for clarity. Never lose actual information — just change how it's presented.

## The six transforms

Apply these in order when rewriting:

### 1. Add context before content

Luca often drops the reader straight into a code example or mental model. Adam needs to know *where he is* first.

Before any technical content, add a short "Background" or intro section that answers:
- What system or project is this about?
- What problem does this feature/pattern solve?
- Why would someone want this?

Keep it to 3-5 sentences. Just enough that Adam isn't asking "wait, what is this for?" when he hits the first code block.

### 2. Lead with the concrete, derive the general

Luca builds from axioms to examples. Flip it:
- Show the specific thing first (a code example, a concrete scenario)
- Then explain the general principle it demonstrates

If the document has an abstract mental model followed by an example, move the example up and weave the mental model into the explanation afterward.

### 3. Name the mechanism explicitly

Luca sometimes writes things like "this replaces the workload" without spelling out *what* does the replacing and *how*. Every time something happens, make sure the reader knows:
- **What** is being acted on
- **What** is doing the acting
- **How** it works (the mechanism)
- **What** the result is

Add inline code comments to spell this out where it helps. A comment like `# This attrset gets merged over super — only keys we set here are replaced` does a lot of work.

### 4. Walk through examples step by step

Where Luca might use a two-column table or ASCII diagram to show relationships, replace it with a narrative walkthrough:

Instead of:
```
A ───ref──→ B    (automatic)
A ───requires──→ C    (manual)
```

Write something like:
> When your YAML mentions resource B by name, that's a `ref` — the dependency is tracked automatically. But resource C selects your pods by label — your YAML never mentions C's name, so there's nowhere for a `ref` to go. You use `requires` to say "include C anyway."

The walkthrough should feel like someone explaining it over a whiteboard, not like a textbook diagram.

### 5. Cut redundant representations

Luca sometimes shows the same concept as code, then a tree diagram, then a table. Multiple representations aren't clarifying for Adam — they're more surface area to reconcile.

Pick the most concrete representation (usually the code with good comments) and fold the insights from the others into prose or inline comments. If a diagram genuinely adds something the code can't show, keep it — but that's the exception.

### 6. Remove details that don't serve the point

Strip out anything that isn't needed to prove the concept:
- Boilerplate fields (full container specs, selector labels, volume details)
- Realistic-but-irrelevant values
- Repeated patterns that don't add new information

Replace stripped sections with `/* ... */` or a brief comment so the reader knows something was there but it's not the point.

## Tone

- Write like a senior colleague explaining something at a whiteboard, not like a textbook
- Use "you" and "your" — address the reader directly
- Short sentences. If a sentence has a semicolon and a dependent clause, it's probably two sentences
- Bold the first use of a new term, then define it immediately

## Process

1. Read the original document completely
2. Identify what the document is actually trying to teach (sometimes this is buried)
3. Restructure using the six transforms above
4. Review the result: does every paragraph earn its place? Could Adam read this top-to-bottom without backtracking?
5. Present the rewrite to Adam and ask if he wants it written to a file
