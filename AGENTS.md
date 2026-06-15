# Comserv Agent Guidelines

Entry point for AI assistants (Cursor, Continue, Zencoder, etc.) working on this repository.

## Canonical standards (read these — not IDE-specific folders)

**Primary index:** `/Documentation/DevelopmentStandards` (in-app) — themes, templates, logging, doc links, file hierarchy.

| Topic | Canonical source |
|-------|------------------|
| **Standards hub** | `/Documentation/DevelopmentStandards` |
| **Theme authoring** | `Comserv/root/static/config/theme_definitions.json`, `/Documentation/CssThemes`, `/Documentation/ThemeConfig` |
| **Template compliance** | `/Documentation/ApplicationTtTemplate`, `/Documentation/DocumentationTtTemplate` |
| **Logging** | `Comserv/lib/Comserv/Util/Logging.pm` (checklist), `/Documentation/logging_best_practices` |
| **Documentation / feature guides** | `/Documentation/DevelopmentStandards#doc-compliance`, `/Documentation/newsletter_feature_guide_workflow` |
| **YAML consolidation** | `Comserv/root/coding-standards-comserv.yaml` |
| **Repo layout & tasks** | `.zencoder/rules/repo.md` (project overview; defers to in-app docs for TT/theme/logging detail) |

**`.zencoder/rules/*.md`** are thin **Zencoder adapters** (`globs`, `alwaysApply`) that point to the sources above. They are not canonical — workstations without Zencoder/PyCharm should use `AGENTS.md` + in-app documentation only.

## Zencoder adapter index (optional — if your IDE loads `.zencoder/rules/`)

- Repo overview: [./.zencoder/rules/repo.md](./.zencoder/rules/repo.md)
- AI behavior: [./.zencoder/rules/ai-behavior.md](./.zencoder/rules/ai-behavior.md)
- Documentation: [./.zencoder/rules/documentation-standards.md](./.zencoder/rules/documentation-standards.md)
- Naming: [./.zencoder/rules/naming-standards.md](./.zencoder/rules/naming-standards.md)
- SQL: [./.zencoder/rules/sql-standards.md](./.zencoder/rules/sql-standards.md)
- Templates/themes: [./.zencoder/rules/template-standards.md](./.zencoder/rules/template-standards.md) → `/Documentation/DevelopmentStandards`
- Logging: [./.zencoder/rules/logging-standards.md](./.zencoder/rules/logging-standards.md) → `Logging.pm`
- Workflow: [./.zencoder/rules/workflow-standards.md](./.zencoder/rules/workflow-standards.md)
- Access: [./.zencoder/rules/application-access-standards.md](./.zencoder/rules/application-access-standards.md)
- Config paths: [./.zencoder/rules/config-location.md](./.zencoder/rules/config-location.md)

## Quick summary

- **Language**: Perl (Catalyst Framework)
- **Database**: MySQL (DBIx::Class ORM)
- **Templates**: Template Toolkit (.tt)
- **Primary Access**: workstation.local:3001
- **Workflow**: Analyze → Plan → Diff → Apply (approval required at each step)

## Deploy awareness (read at session start for prod/debug work)

Before closing Application Error Audit todos or assuming a fix is live on production:

1. Read **`Comserv/DEPLOY_STATUS.json`** — last deploy commit, time, target, status
2. Read **`Comserv/version.json`** — commit baked into the current build/image
3. Run **`git rev-parse --short HEAD`** — compare to `last_deploy.commit`

| Situation | Meaning |
|-----------|---------|
| `HEAD` == `last_deploy.commit` | Production likely has your latest deploy |
| `HEAD` ahead of `last_deploy.commit` | Fixes exist locally only — deploy before closing audit todos |
| Error timestamp after `last_deploy.at_utc` | May be a new bug; investigate |
| Error timestamp before deploy | Likely fixed — close after deploy confirms |

`DEPLOY_STATUS.json` is updated automatically by:
- Admin → Docker Hub deploy (`Comserv::Util::DeployStatus`)
- Production `script/deploy.sh` on successful container health (also copied to NFS logs dir when configured)

Morning Audit scan uses the latest **Docker Hub Deploy** log entry as its window (see `Planning.pm` `_run_audit_scan`).

## Themes — two goals (do not conflate)

| Goal | Task | Where |
|------|------|-------|
| **A — Theme authoring** | Create/change site appearance or mapping | `Comserv/root/static/config/theme_definitions.json` → `ThemeConfig` regenerates `static/css/themes/*.css` |
| **B — Template compliance** | Make `.tt` pages work on every theme | Edit the `.tt` file; use `var(--*)` from `base.css` |

Full detail: **`/Documentation/DevelopmentStandards`** and **`/Documentation/CssThemes`**.

- **Authoring:** Add/edit `themes.{id}.variables`, map site in `site_themes`, save via `/admin/theme` or `ThemeConfig`. Do **not** treat hand-edited CSS as source of truth. Legacy DB `Model::Theme` is deprecated.
- **Compliance (opportunistic):** When creating or editing `.tt` files, improve theme compliance **in that file** — do not sweep the whole repo.

Template compliance steps:
1. **Pick the right base template** — Application UI → `/Documentation/ApplicationTtTemplate`; Documentation → `/Documentation/DocumentationTtTemplate`
2. **Follow** the checklist in those templates and `/Documentation/DevelopmentStandards`
3. **Replace while editing:** hardcoded colours → `var(--*)`, custom buttons → `btn btn-*`, opaque page wrappers → transparent/semi-transparent where needed
4. **Verify mentally** across site themes (CSC, USBM, apis/BMaster) — variables adapt; literals do not

Each `.tt` edit should leave the touched page more consistent site-to-site and theme-to-theme.

## Documentation compliance (lightweight)

1. **Code changes** → append **`/Documentation/CHANGELOG`** (single file; no new `YYYY-MM-DD-*.tt`)
2. **Member how-to** → edit stable **`Documentation/guides/*.tt`** in place, or `page_type=feature_guide`
3. **.tt vs DB vs both** → decide ad hoc per topic (`/Documentation/newsletter_feature_guide_workflow`)

Legacy per-file changelogs: `/Documentation/all_changelog` (read-only). Full rules: **`/Documentation/DevelopmentStandards#doc-compliance`**