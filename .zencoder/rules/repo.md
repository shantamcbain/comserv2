---
description: "Comserv project configuration, file locations, tool boundaries, and Zencoder setup"
alwaysApply: true
---

# Comserv Repository Configuration (Zencoder)

## Repository Metadata

- **Project Name**: Comserv
- **Type**: Perl-based Catalyst Web Application Framework
- **Primary Language**: Perl (Catalyst MVC)
- **Supporting Languages**: Template Toolkit (TT), Bash, SQL, YAML, JavaScript
- **Repository Root**: `/home/shanta/PycharmProjects/comserv2`
- **Main Application**: `Comserv/`
- **Last Updated**: 2025-12-16

---

## Project Overview

Comserv is a comprehensive **multi-site web application management system** built with Catalyst framework. It provides:

- **Project Management System** - Task tracking and hierarchical project structure
- **Documentation System** - Wiki-like documentation accessible through the application
- **Todo Management** - Task and priority management for projects
- **Site Administration** - Multi-tenant site management with custom domains/themes
- **User Management** - Role-based access control (admin, developer, user)
- **Theme System** - Per-site CSS/JS customization
- **API Integrations**:
  - Proxmox (VM management)
  - Cloudflare (DNS management)
  - Ollama (AI queries)
- **Database Modules**:
  - ENCY (Herbal database)
  - BMaster (Bee apiary tracking)
  - Network mapping tools

---

## File Location Reference

### Root-Level Configuration Files

| File/Directory | Location | Zencoder-Related | Purpose |
|---|---|---|---|
| `.zencoder/` | `/home/shanta/PycharmProjects/comserv2/.zencoder/` | ✅ YES | Zencoder AI assistant configuration and session history |
| `.continue/` | `/home/shanta/PycharmProjects/comserv2/.continue/` | ❌ PROJECT | Continue IDE integration (for Continue IDE only, not Zencoder) |
| `.github/` | `/home/shanta/PycharmProjects/comserv2/.github/` | ❌ PROJECT | CI/CD workflows and GitHub Actions configurations |
| `.idea/` | `/home/shanta/PycharmProjects/comserv2/.idea/` | ❌ PROJECT | JetBrains IDE project settings |
| `.qodo/` | `/home/shanta/PycharmProjects/comserv2/.qodo/` | ❌ PROJECT | Code documentation agent configuration |
| `Comserv/` | `/home/shanta/PycharmProjects/comserv2/Comserv/` | ❌ PROJECT | Main application code |
| `temp_files/` | `/home/shanta/PycharmProjects/comserv2/temp_files/` | ❌ PROJECT | Temporary project files |

---

## Zencoder Configuration Structure

### .zencoder Directory

| Item | Path | Type | Purpose |
|---|---|---|---|
| SOLUTION_SUMMARY.txt | `.zencoder/SOLUTION_SUMMARY.txt` | Documentation | Docker/Kubernetes database configuration solution documentation |
| conversation-summaries/ | `.zencoder/conversation-summaries/` | Directory | AI conversation history and summaries |
| docs/ | `.zencoder/docs/` | Directory | Zencoder session documentation |
| logs/ | `.zencoder/logs/` | Directory | AI session logs and diagnostics |
| rules/ | `.zencoder/rules/` | Directory | Custom AI rules for project-specific guidance |
| scripts/ | `.zencoder/scripts/` | Directory | Helper scripts for Zencoder integration |
| delta-history.json | `.zencoder/delta-history.json` | Data | File change history for AI context |
| .gitignore | `.zencoder/.gitignore` | Config | Git ignore rules for .zencoder directory |



## README Files Consolidation

### Existing README Files in Repository

| File | Location | Type | Zencoder-Related | Content Focus |
|---|---|---|---|---|
| Comserv/README.md | `Comserv/README.md` | Project README | ❌ NO | Application overview, development guidelines, and getting started |
| temp_files/README.md | `temp_files/README.md` | Temporary Docs | ❌ NO | Repository structure overview, quick start reference |
| .github/README.md | `.github/README.md` | CI/CD Docs | ❌ NO | GitHub Actions pipeline, deployment workflows, troubleshooting |
| Static READMEs | `Comserv/root/static/*/README.md` | Asset Docs | ❌ NO | Static asset organization (images, icons) |
| Blib READMEs | `Comserv/blib/lib/Comserv/*/README.md` | Built Lib Docs | ❌ NO | Built library documentation (mirrors lib structure) |

### Supporting GitHub Documentation

| File | Location | Purpose |
|---|---|---|
| DEPLOYMENT_QUICK_REFERENCE.md | `.github/DEPLOYMENT_QUICK_REFERENCE.md` | 5-minute deployment overview and common tasks |
| GITHUB_ENVIRONMENTS_SETUP.md | `.github/GITHUB_ENVIRONMENTS_SETUP.md` | GitHub environment configuration (dev/staging/prod) |
| SECRETS_TEMPLATE.md | `.github/SECRETS_TEMPLATE.md` | Secrets checklist, SSH key generation, password guidelines |

---

## Consolidated Project Information

### Key Features

✅ **Core Functionality**
- Multi-site project management
- Hierarchical task tracking
- In-app documentation (Wiki-like)
- Role-based user management
- Theme customization per site

✅ **Infrastructure**
- Docker/Docker Compose support
- Kubernetes migration in progress
- Environment-specific configurations
- Automated CI/CD pipeline
- Backup and restore capabilities

✅ **Integrations**
- Proxmox VM management
- Cloudflare DNS management
- Ollama AI integration
- MariaDB/MySQL databases

### Tech Stack

- **Language**: Perl 5.10+
- **Framework**: Catalyst MVC
- **Template Engine**: Template Toolkit (TT)
- **Database**: MariaDB/MySQL with DBIx::Class ORM
- **Dependency Manager**: Carton
- **Server**: Starman (PSGI)
- **Containerization**: Docker & Docker Compose
- **CI/CD**: GitHub Actions
- **Package Manager**: npm (for some scripts)

### Recent Updates

✅ Fixed project creation issue where 'group_of_poster' was being set to null  
✅ Improved error handling and logging throughout the application  
✅ Enhanced theme system with better organization and customization options  
✅ Docker container database configuration solution for multi-environment deployments  
✅ Environment variable overrides for database configuration (COMSERV_DB_* pattern)  

---

## Getting Started

### Prerequisites

```bash
- Perl 5.10+
- Carton (Perl dependency manager)
- MariaDB/MySQL
- Docker/Docker Compose (optional, for containerized deployment)
- Git
- Node.js (for some scripts)
- API keys: Proxmox, Cloudflare, Ollama (optional)
```

### Quick Start (Development)

```bash
# 1. Navigate to project
cd /home/shanta/PycharmProjects/comserv2

# 2. Install Perl dependencies
cd Comserv
carton install

# 3. Configure database
cp db_config.json.example db_config.json
# Edit db_config.json with your database credentials

# 4. Initialize database
perl script/initialize_db.pl

# 5. Start application
perl script/comserv_server.pl
# OR use Starman for production-like experience
starman -p 5000 script/comserv_server.psgi

# 6. Access application
# Navigate to http://localhost:5000
```

### Docker Deployment

```bash
# Development environment
docker-compose -f docker-compose.dev.yml up

# Staging environment
docker-compose -f docker-compose.staging.yml up

# Production environment
docker-compose -f docker-compose.prod.yml up
```

---

## Development Guidelines

### Code Organization

```
Comserv/
├── lib/Comserv/                    # Application logic
│   ├── Controller/                 # Request routing (Catalyst controllers)
│   ├── Model/                      # Data models (DBIx::Class)
│   ├── Model/Schema/Ency/Result/   # Database entity mappings
│   ├── View/                       # Template rendering views
│   └── Util/                       # Helper utilities
├── root/                           # Public files and templates
│   ├── static/                     # CSS, JS, images (organized by theme)
│   ├── static/css/themes/          # Per-site theme CSS
│   ├── Documentation/              # In-app wiki documentation (.tt files)
│   ├── admin/                      # Admin interface templates
│   ├── todo/                       # Todo module templates
│   └── layout.tt                   # Master template
├── sql/                            # Database schemas and migrations
├── script/                         # Utility scripts
│   ├── comserv_server.pl           # Development server
│   ├── comserv_server.psgi         # PSGI entry point
│   ├── initialize_db.pl            # Database initialization
│   └── deploy_schema.pl            # Schema deployment
├── t/                              # Tests
│   ├── model_*.t                   # Model/Database tests
│   ├── controller_*.t              # Controller action tests
│   └── docker-entrypoint_*.t       # Docker-specific tests
├── config/                         # Configuration files
│   ├── npm-*.conf                  # NPM API configurations
│   ├── supervisord.conf            # Process management
│   └── db_config.json              # Database connections
└── cpanfile                        # Perl dependencies
```

### Coding Standards

- **Perl**: Use Moose for classes, MooseX::Types for type definitions
- **Controllers**: CamelCase naming, chained actions with stash
- **Models**: DBIx::Class for ORM, repository pattern for queries
- **Templates**: Consistent naming (action.tt), use [% INCLUDE %] for partials
- **Documentation**: POD in modules, .tt files for in-app docs (NOT .md for live docs)
- **Comments**: Minimal - prefer self-documenting code

### Testing

```bash
# Run all tests
carton exec prove -l t/

# Run specific test
carton exec prove -l t/model_Todo.t

# Run with verbose output
carton exec prove -lv t/

# Run Docker tests
carton exec prove -l t/docker-entrypoint_non_k8s.t
```

---

## Database Configuration

### Configuration Methods (Priority Order)

1. **Docker Containers**: `/opt/comserv/db_config.json` (mounted volume)
2. **Environment Variables**: `COMSERV_DB_<CONNECTION_NAME>_<FIELD>=value` (Docker override)
3. **Development**: `../../db_config.json` (relative path from code)

### Environment Variable Pattern

```bash
# Format: COMSERV_DB_<CONNECTION>_<FIELD>=value
# Examples:
COMSERV_DB_LOCAL_ENCY_HOST=database
COMSERV_DB_LOCAL_ENCY_USERNAME=comserv
COMSERV_DB_LOCAL_ENCY_PASSWORD=secure_pass

COMSERV_DB_PRODUCTION_SERVER_HOST=192.168.1.198
COMSERV_DB_PRODUCTION_SERVER_USERNAME=prod_user
COMSERV_DB_PRODUCTION_SERVER_PASSWORD=prod_pass
```

### Multi-Environment Setup

```
.env.development        # Dev database settings
.env.staging           # Staging database settings
.env.production        # Production database settings (DO NOT commit)
db_config.json         # Base configuration file (DO NOT commit)
```

---

## Deployment Pipeline

### GitHub Actions Workflows

| Workflow | Trigger | Duration | Purpose |
|---|---|---|---|
| build-and-test.yml | Push to main/develop | 8-12 min | Perl syntax check, unit tests, integration tests, security scan |
| build-push-registry.yml | Build success | 5-8 min | Docker image build, push to registry, vulnerability scan |
| deploy-to-servers.yml | Build completion (dev), Tag push (prod) | 10-15 min | SSH deploy, database migrations, health checks |

### Deployment Environments

- **Development** (develop branch): Auto-deploy to http://dev-server:3000
- **Staging** (main branch): Approval-based deploy to https://staging.example.com
- **Production** (version tags): Approval + backup deploy to https://app.example.com

### Database Migration

```bash
# Via application interface
# Navigate to /admin/migrate_schema

# Or via command line (if available)
perl script/deploy_schema.pl

# Schema comparison
# Navigate to /admin/compare_schema
```

---

## Security Considerations

### Credentials Management

✅ **DO:**
- Store credentials in environment variables
- Use Docker Secrets or Kubernetes Secrets
- Use different credentials per environment
- Keep .env files and db_config.json out of git
- Rotate credentials quarterly

❌ **DON'T:**
- Hardcode passwords in code
- Commit db_config.json to git
- Use same credentials across environments
- Log sensitive values
- Expose database ports externally

### Role-Based Access Control

- **Admin**: Full system access, schema management, user administration
- **Developer**: Code modifications, test environment access
- **User**: Application-only access, role-specific features

---

## Troubleshooting

### Common Issues & Solutions

| Issue | Solution |
|---|---|
| Database connection errors | Verify db_config.json exists and has correct credentials; check COMSERV_DB_* environment variables |
| Starman crashes on port 5000 | Port already in use: `pkill starman; starman -p 5001 ...` or use `/admin/restart_starman` |
| Theme display issues | Browser cache problem: hard refresh (Ctrl+Shift+R); check SiteTheme table in database |
| Docker volume data loss | Ensure volumes mounted in docker-compose.yml; maintain regular backups |
| API integration failures | Verify API credentials in config files; test endpoint connectivity via `/admin/test_api` |
| Application won't start | Check logs: `tail -f root/log/starman.log`; verify all dependencies installed: `carton install` |
| Tests fail | Run locally first: `carton exec prove -lv t/`; check MariaDB is running; verify test database exists |

### Debug Mode

```bash
# Enable debug logging
# In Comserv/comserv.conf:
debug = 1

# View logs
tail -f root/log/starman.log

# Database query debugging
# Navigate to /setup/database to view schema

# Application health check
curl http://localhost:5000/health
```

---

## Directory Structure Map

```
/home/shanta/PycharmProjects/comserv2/
├── .zencoder/                          # Zencoder AI configuration
│   ├── SOLUTION_SUMMARY.txt            # Database config solution doc
│   ├── conversation-summaries/         # AI session summaries
│   ├── rules/                          # Custom AI rules
│   └── scripts/updateprompt.pl         # Prompt update helper
│
├── .github/                            # GitHub configuration
│   ├── workflows/
│   │   ├── build-and-test.yml
│   │   ├── build-push-registry.yml
│   │   └── deploy-to-servers.yml
│   ├── README.md
│   ├── DEPLOYMENT_QUICK_REFERENCE.md
│   ├── GITHUB_ENVIRONMENTS_SETUP.md
│   └── SECRETS_TEMPLATE.md
│
├── Comserv/                            # Main application
│   ├── lib/Comserv/
│   │   ├── Controller/                 # Route handlers
│   │   ├── Model/                      # Data models
│   │   └── Util/                       # Helpers
│   ├── root/
│   │   ├── Documentation/              # In-app wiki (.tt)
│   │   ├── static/css/themes/          # Theme CSS
│   │   └── layout.tt                   # Master template
│   ├── sql/                            # Database schemas
│   ├── script/                         # Utilities & entry points
│   ├── t/                              # Tests
│   ├── config/                         # Configuration files
│   ├── README.md
│   ├── cpanfile                        # Perl dependencies
│   ├── Dockerfile
│   ├── docker-compose.dev.yml
│   ├── docker-compose.staging.yml
│   ├── docker-compose.prod.yml
│   ├── docker-entrypoint.sh
│   └── .env.development
│
├── temp_files/                         # Temporary files
│   └── README.md
│
└── database_initialization_script.sql  # DB initialization
```

---

## Key Configuration Files

| File | Location | Environment | Purpose |
|---|---|---|---|
| db_config.json | `Comserv/` (root) | All | Database connection strings (NOT in git) |
| .env.development | `Comserv/` | Development | Dev environment variables |
| .env.staging | `Comserv/` | Staging | Staging environment variables |
| .env.production | `Comserv/` | Production | Prod environment variables (NOT in git) |
| cpanfile | `Comserv/` | All | Perl module dependencies |
| comserv.conf | `Comserv/lib/Comserv/` | All | Catalyst app configuration |
| supervisord.conf | `Comserv/config/` | Docker | Process management config |
| theme_definitions.json | `Comserv/` | All | Site-to-theme mappings |
| cloudflare_config.json | `Comserv/` | All | Cloudflare API credentials (NOT in git) |

---

## Zencoder Integration Points

### Files for Zencoder Documentation

| File | Purpose | When to Update |
|---|---|---|
| `.zencoder/SOLUTION_SUMMARY.txt` | Implementation documentation | After solving technical problems |
| `.zencoder/rules/IMG_2017.jpg` | (Image reference) | Architecture/design documentation |

### Zencoder Configuration Usage

- **Session History**: All AI conversations tracked in `.zencoder/conversation-summaries/`
- **Change Tracking**: `.zencoder/delta-history.json` maintains file modification history
- **Documentation**: `.zencoder/SOLUTION_SUMMARY.txt` stores technical solutions and decisions

---

## Related Documentation

### Project-Specific Documentation

- **In-App Wiki**: `/Documentation/index` (accessible via application at http://localhost:5000/Documentation)
  - Includes all guides, API documentation, troubleshooting
  - Uses .tt files (Template Toolkit) - NOT .md files

- **GitHub Documentation**: `.github/README.md` and related files
  - Deployment guides
  - CI/CD pipeline documentation
  - Secret management guidelines

### Zencoder-Specific Documentation

- **Solution Archive**: `.zencoder/SOLUTION_SUMMARY.txt`
- **Session History**: `.zencoder/conversation-summaries/` directory
- **Documentation**: `.zencoder/docs/` directory

---

## References & Resources

### Official Documentation
- Catalyst Manual: https://metacpan.org/pod/Catalyst::Manual
- DBIx::Class Guide: https://metacpan.org/pod/DBIx::Class
- Proxmox API: https://pve.proxmox.com/pve-docs/api-viewer/
- Template Toolkit: http://www.template-toolkit.org/

### Quick Start Guides
- **DOCKER_QUICKSTART.txt**: Quick Docker setup
- **DEPLOYMENT_QUICK_REFERENCE.md**: 5-minute deployment guide
- **README.md files**: Various project-specific guides

### Authoritative Sources
- `Comserv/README.md` - Project README
- `.github/` documentation - Deployment procedures
- `.zencoder/SOLUTION_SUMMARY.txt` - Zencoder-specific solutions and decisions

---

## File Classification Summary

### Zencoder Configuration Files

| Status | Category | Count | Examples |
|---|---|---|---|
| ✅ Zencoder | Documentation | 1 | `.zencoder/SOLUTION_SUMMARY.txt` |
| ✅ Zencoder | Session Data | 4 | `.zencoder/conversation-summaries/`, `logs/`, `docs/`, `delta-history.json` |
| ✅ Zencoder | Scripts | 1 | `.zencoder/scripts/updateprompt.pl` |

### Project Configuration Files

| Status | Category | Count | Examples |
|---|---|---|---|
| ❌ Project | Application | 6 | `Comserv/README.md`, `temp_files/README.md`, `.github/README.md`, etc. |
| ❌ Project | CI/CD | 4 | `.github/workflows/*.yml`, `DEPLOYMENT_QUICK_REFERENCE.md`, etc. |
| ❌ Project | Documentation | Multiple | In-app docs in `Comserv/root/Documentation/` |
| ❌ Project | Configuration | Multiple | `docker-compose*.yml`, `.env.*`, `cpanfile`, etc. |

---

## Version Information

- **Repository**: comserv2
- **Framework**: Catalyst (Perl)
- **DB Configuration Solution**: v1.0 (Docker/Kubernetes compatible)
- **Last Updated**: 2025-12-16
- **Documentation Generated For**: Zencoder AI Assistant Configuration
- **Status**: Active Development
