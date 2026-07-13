# Comserv Agent Guidelines

## Primary guidance

**`.hermes.md`** (project root) is the consolidated AI guidance file — auto-loaded every session. Read it first.

## Unique content not in .hermes.md

### Documentation compliance

1. **Code changes** → append `/Documentation/CHANGELOG`
2. **Member how-to** → edit stable `Documentation/guides/*.tt` in place
3. **.tt vs DB vs both** → decide ad hoc per topic

### Module index/summary files

- `.tt` indexes at `Documentation/<Module>/index.tt` — rendered web pages with YAML META blocks
- `.SUMMARY.md` files at `Documentation/<Module>/SUMMARY.md` — plain markdown (<2KB), AI context
- Post-commit hook auto-runs `Documentation/script/sync-docs.sh` on every `git commit` touching `.pm` files
- Manual: `bash Documentation/script/sync-docs.sh` (add `--dry-run` for preview)

### Theme details

| Goal | Task | Where |
|------|------|-------|
| **A — Authoring** | Create/change site appearance | `theme_definitions.json` → `ThemeConfig` generates CSS |
| **B — Compliance** | Make `.tt` work on every theme | Edit `.tt`; use `var(--*)` from `base.css` |

Template compliance: pick right base template (`ApplicationTtTemplate` or `DocumentationTtTemplate`), replace hardcoded colors → `var(--*)`, verify across sites.

### Deploy awareness (morning audit)

Morning Audit uses the latest **Docker Hub Deploy** log entry as its window (see `Planning.pm` `_run_audit_scan`). `DEPLOY_STATUS.json` is updated by Admin → Docker Hub deploy and production `script/deploy.sh`.

### Perl module hygiene scan (full)

```bash
for f in lib/Comserv/Controller/*.pm lib/Comserv/Controller/*/*.pm; do
  [ -f "$f" ] || continue
  pkg=$(grep -m1 '^package ' "$f" | sed 's/^package //;s/;//')
  expected=$(echo "$f" | sed 's|lib/||;s|\.pm$||;s|/|::|g')
  [ "$pkg" = "$expected" ] || echo "MISMATCH $f → $pkg (want $expected)"
done
```

### Quick context

- **Language**: Perl (Catalyst Framework) · **DB**: MySQL (DBIx::Class ORM) · **Templates**: TT (.tt)
- **Primary Access**: workstation.local:3001 · **Workflow**: Analyze → Plan → Diff → Apply

### Full docs (in-app)

- Standards hub: `/Documentation/DevelopmentStandards`
- Theme authoring: `/Documentation/CssThemes`, `/Documentation/ThemeConfig`
- Template compliance: `/Documentation/ApplicationTtTemplate`, `/Documentation/DocumentationTtTemplate`
- Logging: `Comserv/lib/Comserv/Util/Logging.pm` header checklist
