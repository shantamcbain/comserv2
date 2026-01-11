---
description: Repository Information & Zencoder Enforcement Rules
alwaysApply: true
version: "2.1"
last_updated: "2026-01-05"
enforcement_status: "🔴 CRITICAL - Mandatory for all Zencoder agents"
---

# Comserv Application & Zencoder Standards (MANDATORY)

## ⚠️ CRITICAL ENFORCEMENT NOTICE

**This document is MANDATORY reading for ALL Zencoder agents.** Non-compliance results in:
- 🔴 Work HALTED by validation_step0.pl
- 🔴 Chat continuation BLOCKED
- 🔴 /chathandoff execution REQUIRED
- 🔴 Violation escalation to human review

---

## Part 1: Repository Information

### Summary
Comserv is a Perl-based Catalyst web application designed for comprehensive business operations management. It includes project management, documentation systems, user management, and site administration features. The application supports both development and production deployment modes with Docker containerization, using an external MariaDB database and Redis for caching.

## Structure
- **Comserv/lib/** - Application code (Controllers, Models, Views, Utilities)
- **Comserv/script/** - Startup scripts and CLI utilities (comserv_server.pl, initialization scripts)
- **Comserv/root/** - Static files, templates, documentation, logs, sessions
- **Comserv/t/** - Test suites (40+ test files covering controllers, models, views)
- **.github/** - GitHub workflows and deployment configuration
- **Comserv/config/** - Application configuration files
- **Comserv/lib/Comserv/Util/** - Utility modules (Encryption, Logging, Backup, Docker/Proxmox management)

## Language & Runtime
**Language**: Perl  
**Version**: Perl 5.40.0  
**Framework**: Catalyst (v5.90130+)  
**Package Manager**: cpanm (via cpanfile)  
**Application Server**: Starman (production) / Catalyst development server (dev)  
**Process Manager**: Supervisor (production)

## Dependencies

**Core Framework**:
- Catalyst::Runtime (5.90130)
- Catalyst::Plugin::ConfigLoader, Static::Simple, Session, Authentication, Authorization
- Catalyst::View::TT (Template Toolkit)
- DBIx::Class (ORM) with Schema::Loader and TimeStamp support
- Template::Plugin::* (DateTime, JSON, Markdown, DBI, Number::Format)

**Database & Caching**:
- DBD::MariaDB
- DBIx::Class::Migration, EncodedColumn
- Session::Store::File, Cookie, FastMmap, DBIC, Delegate

**Utilities**:
- JSON::MaybeXS, JSON::XS, Config::JSON
- DateTime, DateTime::Event::Recurrence, DateTime::Format::*
- Email::Simple, Email::Sender::Simple
- Crypt::CBC, Crypt::OpenSSL::AES, Crypt::Random, Digest::SHA
- File::Slurp, Archive::Tar, IPC::Run
- LWP::UserAgent, URI::Escape, HTTP::Request
- YAML::Tiny, Text::CSV, MIME::Base64

**Development & Testing**:
- Test::More, Test::Pod, Test::Pod::Coverage, Test::Exception, Test::MockObject
- Test::WWW::Mechanize::Catalyst
- Term::ReadPassword, Term::Size::Any
- Log::Log4perl, Log::Dispatch::Config

**See**: Comserv/cpanfile for complete dependency list (106 packages)

## Build & Installation

### Install Perl Dependencies
```bash
cd Comserv
cpanm --installdeps .
```

### Development Mode (Port 3000)
```bash
perl script/comserv_server.pl
```

### Database Initialization
```bash
perl script/initialize_db.pl
perl script/import_env_to_db.pl
```

### Docker Build & Run
```bash
# Development
docker-compose up web-dev

# Production
docker-compose up web-prod
```

The Dockerfile uses a multi-stage build:
- **Stage 1 (Builder)**: Perl 5.40.0 base, installs CPAN dependencies, verifies core modules
- **Stage 2 (Runtime)**: Slim runtime image with supervisord, Starman, and pre-installed modules

## Docker

**Dockerfile**: Comserv/Dockerfile (multi-stage build)  
**Base Image**: perl:5.40.0  
**Exposed Ports**: 3000 (dev), 5000 (prod)  
**Configuration**: 
- Environment-driven (CATALYST_ENV, CATALYST_DEBUG, WEB_PORT)
- Supervisor manages Starman workers in production
- Health checks via /health endpoint
- External database connection (192.168.1.198)
- Redis for session storage (port 6379)

**Docker Compose Services**:
- **redis** - Redis:7-alpine for caching/sessions (port 6379)
- **web-dev** - Development server with live code reload (port 3000)
- **web-prod** - Production with Starman/Supervisor (port 5000)

**Environment Files**:
- .env.development (local dev config)
- .env.production (prod config template)
- Comserv/db_config.json (database credentials)

## Testing

**Framework**: Test::More with Test::WWW::Mechanize::Catalyst  
**Test Location**: Comserv/t/ (40+ test files)  
**Naming Convention**: `*.t` files (e.g., 01app.t, controller_Admin.t, model_User.t)  
**Configuration**: Tests use Catalyst::Test 'Comserv' for integration testing

**Key Test Files**:
- 01app.t - Basic app initialization and routing
- 02pod.t - POD documentation coverage
- 03podcoverage.t - Full POD coverage verification
- controller_*.t - Individual controller tests
- model_*.t - ORM model tests
- view_TT.t - Template view tests
- Integration tests for Proxmox, Docker, RemoteDB, Schema comparison

**Run Tests**:
```bash
cd Comserv
prove -r t/  # All tests
perl -Ilib t/01app.t  # Individual test
```

## Main Entry Points

**Application Root**: Comserv/lib/Comserv.pm  
**Web Server**: Comserv/script/comserv_server.pl (development with auto-reload)  
**Production Server**: Starman (configured via Supervisor in Docker)

**Key Scripts**:
- comserv_server.pl - Development server with auto-restart
- comserv_test.pl - Test runner
- initialize_db.pl - Database schema initialization
- deploy_ai_tables.pl - AI feature table setup
- docker-entrypoint.sh - Docker startup handler

**Configuration Files**:
- config/comserv.conf - Main application config (YAML)
- db_config.json - Database connection details
- root/static/config/theme_definitions.json - Theme configuration
- .env.development, .env.production - Environment overrides

## Version & Build Info

- **Package**: comserv2
- **Version**: 1.0.0
- **Perl Requirement**: 5.40.0 (via perlbrew recommended)
- **MySQL/MariaDB**: 5.7+ (external server at 192.168.1.198)
- **Redis**: 7-alpine
- **Build System**: Multi-stage Docker build with dependency verification
- **Supported Environments**: Development (3000), Production (5000)

## Development Workflow

1. **Local Development**: Run `docker-compose up web-dev` (live code reload)
2. **Database Changes**: Use DBIx::Class::Migration scripts
3. **Testing**: Run `prove -r t/` before commits
4. **Documentation**: Place in Comserv/root/Documentation as .tt files (not .md)
5. **Themes**: Manage via Comserv/root/static/css/themes/
6. **Deployment**: Use docker-compose with production environment variables

---

## Part 2: ZENCODER MANDATORY STANDARDS (All Agents)

### Rule Z1: Tool Responsibility Boundaries (MANDATORY)

**Status**: 🔴 CRITICAL  
**Enforcement**: Violations BLOCK work and escalate to human review  
**Effective Date**: 2026-01-05

#### What Zencoder MUST Manage
- ✅ `/.zencoder/` directory (rules, scripts, configuration)
- ✅ `/Comserv/root/coding-standards-comserv.yaml` (Zencoder view of project standards)
- ✅ `/Comserv/root/Documentation/session_history/` (chat logs, audit trail, prompts_log.yaml)
- ✅ Enforcement of ask_questions(), /updateprompt, and keyword protocols
- ✅ Compliance validation (validation_step0.pl)

#### What Zencoder MUST NOT Manage
- ❌ `/.continue/` (Continue IDE - Continue tool responsibility)
- ❌ `/.cursor/` (Cursor IDE - Cursor tool responsibility)  
- ❌ `~/.zencoder/` (External user config - user responsibility)
- ❌ System configuration files outside project root
- ❌ Third-party tool rules (Continue, Cursor, OllamaAssist, etc.)

**Violation Consequence**: 
- If agent modifies non-Zencoder files: Work HALTED, violation logged, /chathandoff executed
- User must review violation and reassign work if needed

#### Decision Rule
Before ANY edit outside `/.zencoder/` or `Comserv/root/`:
1. STOP and verify: "Does this file belong to Zencoder responsibility?"
2. If YES: Proceed with edit
3. If NO: Log violation, halt work, exit prompt

---

### Rule Z2: Reference Consolidation (MANDATORY)

**Status**: 🔴 CRITICAL  
**Enforcement**: All agent specifications MUST reference central standards  

#### Single Source of Truth
- **Primary**: `/.zencoder/coding-standards.yaml` (Rules 1-6 + agents section)
- **Secondary**: `/.zencoder/rules/repo.md` (This file - repository info + enforcement)
- **Deprecated** (DO NOT USE):
  - `zencoder-context-configuration.md` (archive only)
  - `keywords.md` v1.0 (replaced by keywords v2.0)
  - `CRITICAL_AGENT_BOUNDARIES.md` (content merged into coding-standards.yaml)

#### Cross-Reference Rules
- ✅ Agent role files (.md) MUST cite coding-standards.yaml line numbers
- ✅ All enforcement references MUST point to coding-standards.yaml Rule N
- ✅ Deprecated files MUST include archive notice + redirect to current source

**Violation Example**: 
❌ "Agent should follow repo.md guidelines" (vague)  
✅ "Agent MUST follow coding-standards.yaml Rule 1 (ask_questions enforcement)" (specific)

---

### Rule Z3: Compliance Protocol (MANDATORY)

**Status**: 🔴 CRITICAL  
**Enforcement**: Non-compliance BLOCKS chat immediately

#### Execution Sequence (STRICT ORDER)
1. **Phase BEFORE**: Execute `/updateprompt.pl --phase before` (plan what will be done)
2. **DO WORK**: Execute edits, create files, run scripts
3. **Phase AFTER**: Execute `/updateprompt.pl --phase after` (log what was actually done)
4. **ASK USER**: Call `ask_questions()` function with structured options
5. **LOG RESPONSE**: On user response, execute `/updateprompt.pl` again to log their answer

#### Violation Pattern (What BREAKS)
- ❌ Do work THEN try to log it (breaks audit trail)
- ❌ Ask text questions instead of ask_questions() (chat hangs)
- ❌ Skip /updateprompt execution (work not tracked)
- ❌ Continue work after asking questions (should WAIT for response)

#### Penalty
- First violation: Logged to prompts_log.yaml with "VIOLATION" tag
- Second violation same chat: /chathandoff auto-executed, session ends
- Third+ violations: Escalated to human review, agent role revoked

---

### Rule Z4: Documentation MUST Centralize to coding-standards.yaml

**Status**: 🔴 CRITICAL  
**Timeline**: 2026-01-05 through 2026-01-31 (consolidation period)

#### What This Means
- All new rules MUST go into coding-standards.yaml (not separate .md files)
- All agent specifications MUST reference coding-standards.yaml sections
- Deprecated .md files MUST be archived (moved to session_history/zencoder_rules_archive/)

#### Permitted Exceptions (ONLY if approved by user)
- Temporary workflow files (agent_pipeline_data.yaml, etc.) - must have expiration date
- Audit reports and JSON files - not subject to consolidation rule
- Archive documentation - clearly labeled as archive-only

---

## DEPRECATION NOTICE

The following files are ARCHIVED effective 2026-01-05. DO NOT REFERENCE:

| File | Reason | Archive Location |
|------|--------|------------------|
| `zencoder-context-configuration.md` | Superseded by repo.md + coding-standards.yaml | zencoder_rules_archive/ |
| `keywords.md` v1.0 | Replaced by modular keywords v2.0 | zencoder_rules_archive/ |
| `CRITICAL_AGENT_BOUNDARIES.md` | Content merged into coding-standards.yaml Rule 6 | zencoder_rules_archive/ |
