# Hermes model preferences (tracked — no secrets)

This file is the branch-aware recommendation matrix. Agents read it from the
checkout; humans apply it with `hermes config set` or a dedicated profile.
Never commit API keys or OAuth tokens.

Last probed free-coder reliability (workstation, **2026-09-08** — live code-gen probe,
not a PONG):

- **`opencode-free` is DEAD for scripted/agent use.** Every model returns
  Cloudflare `403 error code: 1010` (bare client) or `MissingSessionID` /
  `Model is unavailable` (browser UA). The free tier now requires an OpenCode
  client session ID. Do **not** put `opencode-free` in any fallback or
  delegation chain.
- Verified capable on **OpenRouter** (2/2 real code-gen): `ling-3.0-flash-fin:free`
  (~1.2s), `cohere/north-mini-code:free` (~1.6s), `ling-3.0-flash-sante:free`,
  `dots-3-note-preview:free` (512K ctx), `nemotron-3.5-lightning:free` (~10-15s,
  verbose reasoning), `nemotron-3-ultra-550b-a55b:free` (1M ctx, 3.5-54s).
- Flaky → deprioritize: `nemotron-3-super-120b-a12b:free` (1/2),
  `poolside/laguna-s-2.1:free` (429 half the time).
- **Excluded (hard):** `google/gemma-4-31b-it:free` (persistent 429),
  `thinkingmachines/inkling:free` (403 — agentic-harness only).
- **Never hy3 / hy3-free / muse-spark.**
- Ollama (`gemma4-64k` etc.) = **last** (slow if cold). Delegation needs ≥64K context.

## Default coding stack

| Slot | Preference |
|------|------------|
| **Director (primary)** | `xai-oauth` / `grok-composer-2.5-fast` (or current SuperGrok coding pick) |
| **Coder (delegation)** | `nemotron-3.5-lightning-free` — `opencode-free` is dead for scripted use and must never be the coder |
| **Primary fallback order** | Live Hermes chain, Nov 2 2026: `supergrok / grok-4.7` → `openrouter / particle-ai/particle-1` (probation) → `xai / grok-4.7` → `openrouter / openai/gpt-5.6-luna` (probation, stop reached) → `openrouter / cohere/north-mini-code:free`. Free-first probe order when SuperGrok is unavailable: `ling-3.0-flash-fin:free` → `north-mini-code:free` → `nemotron-3.5-lightning:free` → `deepseek-v4-flash` → `deepseek-v4-pro` → `glm-5.3-flash`; **Ollama last**. The source of truth is `@HERMES_CHAIN_DEFAULT` in `Util/AI/ModelChains.pm`, not this row. |
| Aliases | `code` → Director; `cheap` / `delegate` → Coder; `local` → Ollama last-resort |

Live configuration belongs in `~/.hermes/config.yaml` or a profile, not this file.

## Per-branch overrides

Launch sketch (default profile):

```bash
hermes config set model.provider xai-oauth
hermes config set model.default grok-composer-2.5-fast
hermes config set delegation.provider openrouter
hermes config set delegation.model nemotron-3.5-lightning-free
# fallback_providers: edit list — fast free first, Ollama last, no hy3
```

### CSSNavigation

| Slot | Preference | Why |
|------|------------|-----|
| Director | Default coding stack; escalate only for theme-system architecture | CSS, Perl/Catalyst theme paths, and focused UI work |
| Coder | `nemotron-3.5-lightning-free` | Narrow, testable patches after the Director work order is complete |
| Domain | Preserve the 640px class-only navigation contract and canonical theme JSON source | Avoid regressions and configuration drift |

### Documentation

| Slot | Preference | Why |
|------|------------|-----|
| Director | Free-first `nemotron-3.5-lightning-free`; escalate for hard docs architecture | Mostly `.tt`, META, theming, and changelog prose |
| Coder | Same free tier | Mechanical documentation edits |

### schema

| Slot | Preference |
|------|------------|
| Director | Strong composer / deepseek-v4-pro for difficult DDL |
| Coder | Free only for boilerplate Result work after a Director order |

### ai / aisystem / aichatsystem-*

| Slot | Preference |
|------|------------|
| Director | Composer or strong coding model |
| Coder | Lightning/laguna for narrow patches with `CODER_READY` |

### InventoryAccounting / 3d / DockerHA / planning / git-dev

| Slot | Preference |
|------|------------|
| Director | Default coding stack unless pure prose |
| Coder | Default free coder |
| Domain | Honor each branch's database, HA, printing, or planning rules |

## Storage rule

| In git | In `~/.hermes` only |
|--------|---------------------|
| This matrix and process rules | API keys, OAuth, active config, session DB, memories, cron |
| Branch context and app hooks | Optional profiles and installed skills |

Branches document what to prefer; the machine profile enforces it.
