# Hermes model preferences (tracked — no secrets)

This file is the **branch-aware recommendation matrix**. Agents read it from the
checkout; humans apply it with `hermes config set` or a dedicated profile
(`hermes -p <name>`). Do **not** commit API keys or OAuth tokens.

Last probed free-coder reliability (workstation, 2026-08-29):  
`nemotron-3.5-lightning-free` ~4s PONG → preferred free coder.  
`laguna-s-2.1-free` OK but flaky 503. **Never hy3 / hy3-free / muse-spark.**  
Ollama (`gemma4-64k` etc.) = **last** (slow if cold). Delegation needs ≥64K context.

---

## Default (coding / main / general Catalyst)

| Slot | Preference |
|------|------------|
| **Director (primary)** | `xai-oauth` / `grok-composer-2.5-fast` (or current SuperGrok coding pick) |
| **Coder (delegation)** | `opencode-free` / `nemotron-3.5-lightning-free` |
| **Primary fallback order** | lightning → laguna → deepseek free → other free → deepseek flash paid → glm-5.3-flash → deepseek-v4-pro → **Ollama last** |
| Aliases | `code` → Director; `cheap` / `delegate` → Coder; `local` → Ollama last-resort |

Apply sketch (Director session on default profile):

```bash
hermes config set model.provider xai-oauth
hermes config set model.default grok-composer-2.5-fast
hermes config set delegation.provider opencode-free
hermes config set delegation.model nemotron-3.5-lightning-free
# fallback_providers: edit list — fast free first, Ollama last, no hy3
```

---

## Per-branch overrides (intent only — live config via profile or manual set)

Branches may prefer cheaper or domain-tuned stacks. Process (Director+Coder) is
unchanged; only SKUs change.

### Documentation

| Slot | Preference | Why |
|------|------------|-----|
| Director | Free-first OK: `nemotron-3.5-lightning-free` or `laguna-s-2.1-free`; escalate to composer only for hard architecture/docs system design | Mostly `.tt` / META / theming / changelog prose |
| Coder | Same free tier (lightning preferred) | Mechanical META, PageVersion, changelog `.inc`, var(--*) passes |
| Avoid | Paid pro tiers by default; Ollama unless offline | Cost and cold-start |
| Profile hint | `hermes -p documentation` (create profile once; own config/skills) | Isolates fallbacks from coding profile |

Launch:

```bash
cd ~/.comserv/worktrees/Documentation/Comserv && hermes -p documentation chat
# If profile missing, use default profile but READ this section and prefer free Director.
```

### schema

| Slot | Preference |
|------|------------|
| Director | Strong (composer / deepseek-v4-pro for nasty DDL) — Result class + schema-compare only |
| Coder | Free for boilerplate Result stubs only after Director work order; never invent hand-DDL |

### ai / aisystem / aichatsystem-*

| Slot | Preference |
|------|------------|
| Director | composer or strong coding model — Router, V2 JS, voice |
| Coder | lightning/laguna for narrow file patches with CODER_READY |

### InventoryAccounting / 3d / DockerHA / planning / git-dev

| Slot | Preference |
|------|------------|
| Director | Default coding stack unless task is pure prose |
| Coder | Default free coder |
| Domain | Honor branch `.hermes.md` domain rules (DB, HA, printing_3d, etc.) |

---

## How much belongs in the branch vs home dir

| In **git** (this checkout) | In **`~/.hermes`** only |
|----------------------------|-------------------------|
| Process (director-coder.md) | API keys, OAuth, live config.yaml |
| This models.md matrix | Session DB, memories, cron |
| Branch `.hermes.md` domain + “use row X from models.md” | Optional profiles (`profiles/documentation/`) |
| App hooks (Logging/TodoLog) | Installed skills copies (unless vendored later) |

**Rule:** branches teach *what to prefer*; the machine profile *enforces* it.
When opening a branch worktree, either switch profile or have Director apply the
row above before long runs.
