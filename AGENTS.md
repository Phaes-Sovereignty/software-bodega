# AGENTS.md — read this first

This is a **software factory**: a pipeline that turns an idea into verified code
with one human touch per stage.

**Where state lives — on disk, never in chat history:**
- `factory/STATE.md` — current stage + pointer. Single source of truth.
- `factory/BRIEF.md` `BLUEPRINT.md` `CONTRACT.md` `HANDOFF.md` `REVIEW.md` `GUIDE.md`
- `factory/.planning/{spec,decompose,plan}.json` — machine-checked artifacts
- `factory/.planning/gate-results/` — `<gate>-<sha>.json` verdicts
- `factory/tasks/*.md` — one file per task
- `factory/progress.md` `factory/log.md` — append-only diaries. Never rewrite.

**Rules that do not bend:**
1. One agent per station. One task per fresh context window. No multi-agent chat.
2. Every gate anchors to something mechanical. LLM judges are fallbacks and must
   be a different model FAMILY than the author.
3. `factory/tests/heldout/` is **held out**. Never read it, never reference it,
   never write to it. If you can see it, that is a bug — report it.
4. Repair loops cap at 2. Then resample N=3. Then PARK. Never loop forever.
5. Never weaken a test to make it pass. Never edit `CONTRACT.md` — it is signed.
6. `git add` specific paths. Never `git add -A`.

**Every output ends with this block, exactly:**
```
---FACTORY_STATUS---
STATION: <name>
TASK_ID: <id or ->
STATUS: DONE | BLOCKED | NEEDS_CONTEXT
SUMMARY: <one line>
---END---
```

**Authority:** once `foreman/` exists (Phase C), the foreman owns station
transitions for the bootstrap pipeline — its verdict beats any agent's opinion.
The Small Loop (`scripts/runner.sh` + CI) stays scripts + CI forever, by design.

Roles, not model names: see `models.env`.
