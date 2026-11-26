# User-facing text

Claude Code loads this file together with `CLAUDE.md`. Other documents cite
these sections as `CLAUDE.md` § Copywriting / positioning and `CLAUDE.md` §
User-facing text.

## Copywriting / positioning

When editing homepage, README, pitch, or positioning copy, preserve strong
existing copy unless the user explicitly asks for a full rewrite. Prefer minimal
surgical edits over replacing concise positioning with explanatory prose.

For Kix public copy:

- Lead with: "Kix is a Kubernetes compiler."
- Keep "verifiable cluster artifact" as canonical language unless the user asks
  to test alternatives.
- Do not lead with "emits standard Kubernetes resources"; that is an
  interoperability reassurance, not the core pitch.
- Default flow is: define -> evaluate/check -> preview -> deploy.
- Local/pre-commit feedback comes before PR/CI feedback.
- Avoid sentence-ending "with confidence"; prefer "know what will happen before
  they change Kubernetes."

Before writing ANY prose (including code comments and docstrings), read
`CLAUDE.prose.md` for
Adam's accumulated writing corrections (no em dashes, banned words, AI-tell
constructions, messaging constraints). Add to it when he corrects style.

## User-facing text: copy pass

Claude writes code well and prose badly. Antigravity, running Gemini 4 Carbon by default, writes much clearer user-facing text. Before opening a pull request that adds or rewrites text a person reads, run `scripts/copy-pass` on the branch. That text includes errors, warnings, and log lines in `cli/` and `kix/`, docs pages, skills, and change records in `changes/`. The script hands the changed text to Carbon, which edits the files in place using `CLAUDE.prose.md` for writing rules and the code and docs as its only source of facts. Review Carbon's edits and check every claim it adds against the code. Keep its wording unless a claim is false. If a claim is false, send it back to Carbon with the right facts instead of rewriting the text yourself. Then run the tests again (some check message text word for word) and commit. Set `COPY_PASS_MODEL` to run `scripts/copy-pass` with a different model.

After `scripts/copy-pass` exits 0, add `- [x] Copy pass` to the pull request description. Never tick the box unless the script ran and exited 0. If `agy` is not installed, `scripts/copy-pass` exits 2. Add an unticked `- [ ] Copy pass` box instead. Include the checkbox whenever the pull request adds or rewrites prose, such as a new error message or a reworded docs page. Leave it out for purely mechanical edits, such as a version bump, a renamed path, or a line citation. The Copy pass workflow passes when the box is ticked or omitted, and fails on an unticked box until someone with `agy` runs the pass.

For an important new message, such as a refusal that stops a deploy, you can also give Carbon the facts and have it draft the text directly: `agy --model "Gemini 4 Carbon (Medium)" --print "<facts and request>"`. Describe who reads it, what they just did, and what they can do next. Ask for the full output as it appears on screen rather than separate strings.
