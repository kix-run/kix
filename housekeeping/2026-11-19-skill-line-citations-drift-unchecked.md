# 2026-11-19 · `.claude/skills/package-authoring/SKILL.md` · Line citations into packages go stale and nothing checks them.

At commit 5d8cfee6 every `immich:<line>` citation in the skill pointed at the wrong code: `immich:107` was a blank line and `immich:192-195` was the extension check, not `renamedFrom`. Any header edit shifts them. A check that each cited range contains an expected token, or citations by symbol instead of line, would stop the drift.
