---
description: "Comserv Project Overview and Architecture"
globs: []
alwaysApply: true
---

# Comserv Project Guide

> **Standards canonical index:** `/Documentation/DevelopmentStandards` (in-app).  
> TT/theme/logging detail lives in in-app docs and `coding-standards-comserv.yaml` — not duplicated here.  
> This file is project overview + common tasks; `.zencoder/rules/` entries are Zencoder adapters.

## Project Overview

Comserv is a Perl-based web application framework using Catalyst, serving as a multi-site management system. It handles various modules like task tracking (Todo), user authentication, documentation management, network mapping, bee apiary tracking (BMaster), herbal database (ENCY), and integrations with Proxmox for VM management, Cloudflare for DNS, and Ollama for AI queries. The app supports role-based access (admin, developer, user) and is designed for deployment in containerized environments.

### High-Level Architecture
- **MVC Pattern**: Controllers (request routing), Models (DB/ORM), Views (TT rendering).
- **Multi-Tenancy**: Sites with custom themes/domains via `Site` and `ThemeConfig` models.
- **Auth/Security**: Catalyst sessions with roles; admin tools for git/schema/backup.
- **Modular**: Separate controllers for domains (e.g., Todo, Proxmox); extensive in-app docs.
- **Assumption**: Kubernetes migration in progress (verify via `Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt`).

## Features
- Project management system
- Theme customization system
- Email integration
- PDF generation
- Proxmox VE integration
- Multi-site support

## Getting Started

### Prerequisites
- Perl 5.10+, Carton (dependency manager).
- MariaDB/MySQL.
- Docker/Docker Compose.
- Git, Node.js (for some scripts, assumption – verify).
- API keys: Proxmox, Cloudflare, Ollama (optional).

### Installation Instructions
1. Clone: `git clone <repo> && cd Comserv`.
2. Deps: `carton install`.
3. DB: Run `sql/database_initialization_script.sql`; initialize with `script/initialize_db.pl`.
4. Config: Edit `db_config.json` (from template); set env vars (see `.github/SECRETS_TEMPLATE.md`).
5. Docker: `docker-compose -f docker-compose.dev.yml up`.
6. Server: `starman -p 5000 script/comserv_server.psgi` or use `script/comserv_server.pl`.

### Basic Usage Examples
- Home: `http://localhost:5000` – site selection.
- Login: `/user/login` (user) or `/admin/index` (admin).
- Docs: `/Documentation/index` – browse/view/edit.
- Todo: `/todo/todo` – list/add tasks.
- Proxmox: `/proxmox/index` – manage VMs (if configured).

### Running Tests
- `carton exec prove -l t/` for all tests.
- Models: `t/model_Todo.t`, controllers: `t/controller_Admin.t`.
- Docker tests: `t/docker-entrypoint_non_k8s.t`.
- Coverage: Use Devel::Cover (assumption – add if needed).

## Project Structure

### Overview of Main Directories
- **lib/Comserv/**: App logic.
  - **Controller/**: Routes (e.g., `Admin.pm` for tools).
  - **Model/**: Data (e.g., `Schema/Ency/Result/Todo.pm`).
  - **View/**: Rendering (e.g., `TT.pm`).
  - **Util/**: Helpers (e.g., `BackupManager.pm`).
- **root/**: Public files.
  - **static/**: Assets (CSS/JS in themes).
  - **Documentation/**: .tt docs for in-app wiki.
  - Subdirs like `admin/`, `todo/` for templates.
- **sql/**: Schemas (e.g., `page_tb.sql`).
- **script/**: Scripts (e.g., `deploy_schema.pl`).
- **t/**: Tests.
- **.github/workflows/**: CI/CD YAMLs.
- **config/**: Nginx/MySQL configs.

### Key Files and Their Roles
- **cpanfile**: Perl deps.
- **lib/Comserv.pm**: Catalyst app config.
- **root/layout.tt**: Master template.
- **docker-compose*.yml**: Env setups (dev/prod).
- **script/comserv_server.psgi**: PSGI entry.
- **.github/workflows/build-and-test.yml**: CI pipeline.

### Important Configuration Files
- **db_config.json**: DB connections (multi-site).
- **comserv.conf**: App settings (debug, plugins).
- **cloudflare_config.json**: API auth.
- **static/config/theme_definitions.json**: Theme variables + `site_themes` mapping (canonical; CSS generated to `static/css/themes/`).
- **supervisord.conf**: Docker process mgmt.

## Development Workflow

### Coding Standards
- Moose for classes (types via MooseX::Types).
- TT: Consistent naming (`action.tt`), includes via `[% INCLUDE %]`.
- Comments/POD: In modules; docs in .tt files.
- Naming: CamelCase controllers, snake_case DB fields.
- Assumption: Perl::Critic for linting (verify/add).

### Testing Approach
- Unit: Model resultsets (`t/model_*.t`).
- Functional: Controller actions (`t/controller_*.t`).
- Integration: App startup (`t/01app.t`), Docker behaviors.
- Run in CI; mock DB for isolation.

### Build and Deployment Process
- Build: `carton install && docker build .`.
- Test: GitHub Actions (build/test/push/deploy).
- Deploy: `docker-compose up -d`; schema migrate via `/admin/migrate_schema`.
- Staging/Prod: Separate compose files; Kubernetes planned.
- Rollback: `/admin/emergency_restore`.

### Contribution Guidelines
- Branch: `feature/<name>`.
- PR: Update tests/docs; reference issues.
- Review: Check for security (auth bypasses).
- Docs: Edit `Documentation/` .tt files.
- Commit: Semantic messages; sign commits.

## Key Concepts

### Domain-Specific Terminology
- **Site**: Isolated tenant with domain/theme (e.g., ve7tit).
- **Project/Todo**: Task hierarchies with sites, priorities.
- **Theme**: Per-site CSS/JS overrides.
- **Schema**: DB structure; multi-schema support.
- **Starman**: Production server; diagnostics via util.
- **Proxmox Node**: VM host in integration.

### Core Abstractions
- **Result Classes**: DBIx::Class for entities (e.g., Todo, User).
- **Actions**: Chained/stash in controllers.
- **Helpers**: Utils for common ops (e.g., auth checks).
- **Configs**: JSON-driven (DB, themes, APIs).

### Design Patterns
- MVC (Catalyst).
- Repository (Models for DB).
- Decorator (Themes wrapping base CSS).
- Observer (Logging in utils).
- Chain of Responsibility (Controller actions).

## Common Tasks

### Step-by-Step Guides
1. **Add Controller Action**:
   - In `lib/Comserv/Controller/Module.pm`: `sub new_action :Local { my ($self, $c) = @_; $c->stash->{key} = 'value'; }`.
   - Template: `root/module/new_action.tt`.
   - Test: `t/controller_module.t`.
   - Doc: Update `Documentation/controllers/Module.tt`.

2. **Schema Migration**:
   - Add SQL to `sql/` or Result class.
   - Deploy: Run `script/deploy_schema.pl` or in-app `/admin/migrate_schema`.
   - Compare: `/admin/compare_schema`.

3. **Create or update a theme**:
   - Edit `Comserv/root/static/config/theme_definitions.json` (`themes.{id}.variables`, `site_themes.{site}`).
   - Regenerate CSS: `/admin/theme` save actions or `ThemeConfig->generate_all_theme_css`.
   - Output: `Comserv/root/static/css/themes/<id>.css` (generated — do not treat as source of truth).
   - Map site → theme in `site_themes`; verify at `/admin/theme`.

4. **Backup/Restore**:
   - Create: `/admin/backup/create`.
   - Restore: `/admin/backup/restore <id>`.
   - Test: `/admin/backup/test_connections`.

5. **Integrate Proxmox**:
   - Config: Add server in `/proxmox/add_server`.
   - API: Use `Model/Proxmox.pm` for calls.
   - Test: `/proxmox/test_result`.

### Examples
- Query Todo: `$c->model('DBEncy::Todo')->search({ due => { '<=' => $date } })`.
- Stash for View: `$c->stash->{todos} = $rs;`.
- Git Pull: In-app `/admin/git_pull` or CLI `git pull`.

## Troubleshooting

### Common Issues
- **DB Errors**: Verify `db_config.json`; run `script/initialize_db.pl`. Solution: Check MariaDB logs.
- **Starman Crashes**: Port conflict (5000). Solution: `pkill starman; starman -p 5001 ...`; use `/admin/restart_starman`.
- **Theme Mismatch**: Wrong `site_themes` mapping or stale CSS. Solution: Hard refresh; verify `static/config/theme_definitions.json`; run `generate_all_theme_css`.
- **Docker Volume Lost**: Data persistence. Solution: Mount volumes in compose; backup DB.
- **API Fail (Proxmox/Cloudflare)**: Invalid tokens. Solution: Update configs; test endpoints.
- **Auth Bypass**: Role checks fail. Solution: Verify `Util/AdminAuth.pm`; add logs.
- **Slow Queries**: No indexes. Assumption: Add in schema (verify perf).

### Debugging Tips
- Logs: `tail -f root/log/starman.log`; in-app `/log/logs`.
- Debug Mode: Set `debug => 1` in conf; use `$c->log->debug()`.
- DB: `/setup/database` for schema view; SQL profiler.
- Network: `/admin/network_diagnostics`.
- Tests: `prove -v t/` for verbose.

## References
- **Catalyst Manual**: https://metacpan.org/pod/Catalyst::Manual.
- **DBIx::Class**: https://metacpan.org/pod/DBIx::Class.
- **Proxmox API**: https://pve.proxmox.com/pve-docs/api-viewer/.
- **In-App**: `/Documentation/` (e.g., `developer_guides.tt`, `changelog/`).
- **CI/CD**: `.github/workflows/` YAMLs.
- **Quickstarts**: `DOCKER_QUICKSTART.txt`, `.github/DEPLOYMENT_QUICK_REFERENCE.md`.
- **Assumption**: External links current as of analysis; verify.

# Systematic Debugging Protocol

## MANDATORY DEBUGGING WORKFLOW

### Step 1: Complete Analysis Phase
1. **Read Zencoder Guidelines**: Review all .zencoder/rules/ files.
2. **Read Application Documentation**: Study relevant .tt documentation files.
3. **Read Codebase Components**:
   - Controllers (*.pm in Controller/)
   - Models (*.pm in Model/)
   - Templates (*.tt in root/)
   - Schema files (Result/*.pm)
4. **Application Log Analysis**: Read `/Comserv/logs/application.log`.
5. **Trace Execution Path**: Follow code path that leads to error.

### Step 2: State Comparison & Documentation
1. **Document Current State**: What the code actually does.
2. **Document Expected State**: What documentation says it should do.
3. **List Discrepancies**: All differences between docs and code.
4. **Error Analysis**: Actual errors vs expected behavior.
5. **Create Fix Plan**: Include both code fixes and documentation updates.

### Step 3: Implementation Priority
1. **Fix Documentation Discrepancies FIRST**: Align docs with current code.
2. **Implement Bug Fix**: Apply necessary code changes.
3. **Update Documentation**: Reflect new functionality.
4. **Test Implementation**: Verify fix works correctly.
5. **Document Changes**: Record what was changed and why.

### Step 4: Verification & Commit
1. **Final State Check**: Ensure docs and code are synchronized.
2. **Test Complete Workflow**: Verify end-to-end functionality.
3. **Present Changes**: Show all modifications in diff format.
4. **Commit Preparation**: Ready for version control.
5. **Update Task Status**: Mark completed items, note remaining work.

## Log Analysis Protocol
- **Primary Log**: `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log`.
- **Error Patterns**: Look for stack traces, method calls, variable states.
- **Execution Flow**: Trace request path through controllers and models.
- **Debug Mode**: Enable session debug_mode for detailed output.
