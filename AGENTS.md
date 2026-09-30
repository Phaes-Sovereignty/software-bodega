# AGENTS.md — read this first

This is **Software Bodega**, a software factory: a pipeline that turns an idea into verified code
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
3. The **held-out suite** is held out. Its directory is whatever
   `factory/toolchain.env` declares as `HELDOUT_DIR` (`factory/tests/heldout/`
   by default, `Tests/HeldoutTests` for SwiftPM) — ask
   `bash scripts/toolchain.sh get HELDOUT_DIR`, do not assume the default.
   Never read it, never reference it, never write to it. If you can see it, that
   is a bug — report it.
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

**Launch the night shift with `bash scripts/foreman.sh launch`, not
`scripts/nightshift.sh`.** `launch` runs it inside a sparse-checkout worktree
where the held-out suite does not exist; calling the script directly puts every
worker next to its own exam. The loop prints `seal: NONE` and logs it when that
happens — that line is not decoration, and neither is the seal.

Roles, not model names: see `models.env`.
