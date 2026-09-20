# Housekeeping — logging problems we are not fixing

The [`housekeeping/`](housekeeping/) directory at the repo root collects
the problems we notice and leave: rough edges, stale docs, slow
commands, confusing names, bugs we stepped around, rules that fire where
they should not. One problem, one file. This file is how to use it.

To read the lot: `cat housekeeping/*.md`. For a one-line index:
`head -qn1 housekeeping/*.md`.

## Write in plain language

Entries follow ISO 24495-1, the plain language standard, along with the
house voice in [`CLAUDE.prose.md`](CLAUDE.prose.md). Someone reads the
entry months later with none of your context, and a review agent reads
it alongside a hundred others.

- **Say what is wrong in the first line**, before the background.
- **Give every sentence a subject and a finite verb.** Short sentences,
  common words, one idea each.
- **Make the point, then give the reason.**
- **Use the technical word only when it is the name of the thing.**
- **Name what you saw**: a path, a command, a rule id, a warning message.

## Adding an entry

Write it the moment you notice the problem, and commit it. Approval is
not needed, any branch will do, and it can ride along in any pull
request. The problem does not have to relate to the work in hand,
because reading some nearby code that looked wrong is reason enough.

Write one new file, named for the date and a short slug:

    housekeeping/YYYY-MM-DD-short-slug.md

The slug names the thing and then its problem —
`from-workload-cannot-build-headless-service`, not `service-bug`. Three
to six words, lowercase letters, digits and hyphens. Someone scanning
`ls` should be able to tell your entry from the hundred around it.

The file holds a heading and a few lines under it:

```markdown
# YYYY-MM-DD · `path/or/subsystem` · The problem in one sentence.

What it costs us and how it shows up. Where to look.
```

Date the entry the day you write it, whatever age the problem turns out
to be. Four lines is enough, and longer usually means a solution has
crept in.

A file each is what keeps this out of everybody's way. Two agents on two
branches write two different files, so neither has a merge conflict to
resolve and no entry is ever lost to one.

## Rules

- **Entries are problems.** The fix for six related entries is rarely
  the fix any one of them suggests, so we look for it later across a
  month of entries at once, with `/housekeeping-review`.
- **Check for an entry that already covers it.** Search first:
  `grep -ril <keyword> housekeeping/`. When one exists, add a line to
  that file — `- Hit again YYYY-MM-DD while <what you were doing>.`
  How often a problem recurs is the signal we most want.
- **Record it and carry on.** Fix the problem itself only when the fix
  already sits inside the work you have.
- **Delete the file once its problem is fixed.** `git rm` it, in the
  commit that fixes it where there is one. Where the fix landed
  somewhere else, in a console, a forge setting, another repository,
  delete the file anyway. Remove it rather than marking it done or
  rewriting it into a record of the fix: the directory is the list of
  problems still open, and an entry that says it is closed costs a
  reader the same attention as a real one. Git history keeps the record.
- **Housekeeping is not the roadmap.** A missing feature goes in
  `ROADMAP.md`; a design still being argued goes in `v2_discussions/`.
  An entry here is something that is wrong today.
- **Say when a decision is required.** Some problems have no fix until
  someone chooses between designs. Write "Decision required from
  <who>:" as its own line, name the choice in a few words, and link the
  `v2_discussions/` doc that frames it. Without that line a reader
  assumes the entry is waiting for time, not for a call, and the review
  keeps re-triaging it.

Reviews of the whole directory land in `housekeeping/reviews/`.
