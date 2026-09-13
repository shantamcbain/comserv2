# Director + Coder (shared process — all branches)

Tracked in git so every worktree/branch sees the same workflow after merge.
Live API keys and the active `~/.hermes/config.yaml` stay on the machine (not in git).

## Roles

| Role | Who | Job |
|------|-----|-----|
| **Director** | Whatever model is primary for this Hermes session | Diagnose, write/upgrade the **todo work order**, review coder output |
| **Coder** | Cheap/free tier (`delegation.*` or `/model cheap`) | Execute only what is already on the todo — no re-plan |

Director is **model-agnostic**: if primary is composer today and Laguna tomorrow, that primary is still Director.

## Every todo touch (Hermes or app)

1. Read the todo. If `description` lacks ROOT / DO / DO NOT / ACCEPT, Director fills it (or marks BLOCKED).
2. Put executable steps on the todo; set comments `CODER_READY` / `plan_rev:` when a coder may run.
3. Coder follows DO only; append learnings to comments (never wipe).
4. Error-audit todos: app seeds a stub (`Logging.pm`); Director replaces stub with a real work order before coding.

App soft hooks (once merged): empty Start → `WORK_ORDER_NEEDED` on comments; new `[Error]` todos get a work-order stub.

## Work-order template (todo description)

```
plan_rev: YYYY-MM-DD
ROOT CAUSE / CONTEXT:
...
DO:
1. ...
DO NOT:
- ...
ACCEPT:
- ...
```

## Config vs git

| What | Where |
|------|--------|
| Process rules (this file) | **Git** — `.hermes/director-coder.md` |
| Recommended models per branch | **Git** — `.hermes/models.md` |
| Active primary / fallback / API keys | **`~/.hermes/config.yaml`** (or `hermes -p <profile>`) |
| Per-branch domain rules | Branch checkout `.hermes.md` (honor global, then domain) |

Fallback lists in `config.yaml` rescue the **Director** only. Coder is a single `delegation.*` slot unless Director repoints it.

## Skill

User-local skill (optional install): `comserv2-hermes-director-coder` under `~/.hermes/skills/`.
Canonical process text for the repo is **this file** — keep skill and this file aligned when process changes.
