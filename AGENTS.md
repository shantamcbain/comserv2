# Comserv Agent Guidelines

This file is a reference for AI agents working on the Comserv project. 

**STRICT ADHERENCE REQUIRED**: All AI agents MUST read and follow the rules defined in the `.zencoder/rules/` directory. These rules are the single source of truth for project standards, workflows, and behavior.

## Core Rules Reference
- **Repo Overview**: [./.zencoder/rules/repo.md](./.zencoder/rules/repo.md)
- **AI Behavior**: [./.zencoder/rules/ai-behavior.md](./.zencoder/rules/ai-behavior.md)
- **Documentation Standards**: [./.zencoder/rules/documentation-standards.md](./.zencoder/rules/documentation-standards.md)
- **Naming Standards**: [./.zencoder/rules/naming-standards.md](./.zencoder/rules/naming-standards.md)
- **SQL Standards**: [./.zencoder/rules/sql-standards.md](./.zencoder/rules/sql-standards.md)
- **Logging Standards**: [./.zencoder/rules/logging-standards.md](./.zencoder/rules/logging-standards.md)
- **Workflow Standards**: [./.zencoder/rules/workflow-standards.md](./.zencoder/rules/workflow-standards.md)
- **Access Standards**: [./.zencoder/rules/application-access-standards.md](./.zencoder/rules/application-access-standards.md)
- **Config Standards**: [./.zencoder/rules/config-location.md](./.zencoder/rules/config-location.md)

## Quick Summary
- **Language**: Perl (Catalyst Framework)
- **Database**: MySQL (DBIx::Class ORM)
- **Templates**: Template Toolkit (.tt)
- **Primary Access**: workstation.local:3001
- **Workflow**: Analyze -> Plan -> Diff -> Apply (Approval required at each step)

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
