---
description: "Zencoder adapter — module summary context files (.SUMMARY.md)"
globs: ["Comserv/lib/Comserv/Controller/**", "Comserv/lib/Comserv/Model/**"]
alwaysApply: false
---

# Module Summary Context (.SUMMARY.md)

Comserv uses `.SUMMARY.md` files alongside `.tt` index files for AI context efficiency.  
These are plain markdown files (<2KB each) that summarize module structure.

## How to use

When working in a controller/model file, check for a corresponding summary:

- `Documentation/<Module>/SUMMARY.md` — per-module summary
- `Documentation/SUMMARY.md` — master controller index
- `CLAUDE.md` — full codebase map (always loaded)

Run `Documentation/script/sync-docs.sh` from project root to refresh auto-detected sections.

## Auto-sync

If you add a new controller or model, commit the change — the post-commit hook (`.git/hooks/post-commit`) automatically:
1. Scans for new `.pm` files
2. Updates CLAUDE.md auto-detected section
3. Creates stub SUMMARY.md for new modules
4. Stages the doc changes

No manual update needed — just commit your code.