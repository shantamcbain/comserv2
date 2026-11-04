# Hermes model preferences (tracked — no secrets)

This file is the branch-aware recommendation matrix. Agents read it from the
checkout; humans apply it with `hermes config set` or a dedicated profile.
Never commit API keys or OAuth tokens.

## Reliability notes

- `opencode-free` is not usable for scripted or agent work; do not put it in a
  fallback or delegation chain.
- Preferred free coding options are `ling-3.0-flash-fin:free`,
  `cohere/north-mini-code:free`, `ling-3.0-flash-sante:free`,
  `dots-3-note-preview:free`, and `nemotron-3.5-lightning:free`.
- `nemotron-3-super-120b-a12b:free` and `poolside/laguna-s-2.1:free` are flaky
  and should be deprioritized.
- Never use `hy3`, `hy3-free`, `muse-spark`, or persistent-429 free models.
- Ollama is a last resort because cold starts are slow; delegation needs at
  least 64K context.

## Default coding stack

| Slot | Preference |
|------|------------|
| Director | `xai-oauth` / current SuperGrok coding pick |
| Coder | `nemotron-3.5-lightning-free` |
| Primary fallback order | ling free → north-mini-code free → ling sante free → dots free → nemotron lightning free → nemotron ultra free → deepseek flash/pro → glm flash → Ollama last |
| Aliases | `code` → Director; `cheap` / `delegate` → Coder; `local` → Ollama last-resort |

Live configuration belongs in `~/.hermes/config.yaml` or a profile, not this file.

## Per-branch overrides

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
