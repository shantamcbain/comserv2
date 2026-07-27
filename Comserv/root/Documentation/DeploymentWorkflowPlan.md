# Deployment Workflow Plan

**Version:** 1.1  
**Last Updated:** 2026-07-27  
**Status:** Planning Phase (see "Incidents & Fixes" for shipped deploy.sh changes)

## Incidents & Fixes

### 2026-07-27 — Production "restart loop" (FIXED, commit 76135ef0)

**Symptom:** production1 repeatedly restarted the `comserv2-web-prod` container, making the site intermittently unusable.

**What was actually wrong:** the container was never crashing (Docker showed RestartCount=0, clean exit, healthy). The restarts were self-inflicted by the monitoring cron:

```
*/10 * * * * DEPLOY_MODE=monitor /opt/comserv/Comserv/script/deploy.sh
```

In monitor mode, `sync_host_app_lib()` in `script/deploy.sh` unconditionally `docker cp`'d the host `lib/` into the container and then `docker restart`ed it on EVERY 10-minute tick — even when `git pull` reported "Already up to date". Result: 6 production restarts per hour, each with a ~60s health-check start period during which the site was down.

**Fix (deploy.sh):** `sync_host_app_lib()` now computes a sha256 checksum over the host `lib/**/*.pm` tree and stamps it inside the container at `/opt/comserv/.lib_sync_hash`. Sync + restart only occur when the hash differs from the stamp; otherwise it logs `lib unchanged — skipping sync and restart`. The stamp survives `docker restart` but dies with container recreation (correct — a fresh container gets a fresh sync).

**Verified on production1:** first monitor run after the fix synced + restarted once (stamping the hash); the immediately-following run skipped. 

**Lesson:** a "restart loop" is not always the app crashing — check `docker inspect` RestartCount/ExitCode and `docker events` before assuming the container is at fault; our own automation was the actor.

### 2026-07-27 — Production disk at 99% (cleaned up, watch item)

**What was wrong:** 30G root LV at 99% (448M free). At 100% the container really does die (session/log writes fail) — this was the second, genuine flavor of production outage.

**Done:** removed stale `bk-comserv2-web-prod` backup image (3.3GB) + dangling layers, and 42 orphaned Docker volumes from earlier deploy runs (`comserv-deploy-2026070*_*`, doubled `comserv2_comserv2_*` names, old whisper venvs). Preserved `comserv2_nfs_data` and all volumes mounted by the running container. Result: 91% used, 2.8G free.

**Watch items / future work:**
- The 8.5GB prod image (baked Whisper venv) dominates the disk; long-term either slim the Whisper layer or grow the 30G LV.
- The deploy backup step creates `bk-comserv2-web-prod:*` images (3.3GB each); ensure old backups are pruned after a successful deploy so they don't re-fill the disk.
- Volume-normalization in deploy.sh previously left doubled `comserv2_comserv2_*` names behind; if these reappear, the normalization step is recreating rather than renaming.

## Overview

This document outlines the planned deployment workflow for Comserv2 that addresses the logical impossibility of restarting a server from within itself while providing safe testing and deployment capabilities.

## Current Problem

The current restart functionality attempts to restart Starman from within Starman itself, which is logically impossible and causes the interface to become unavailable during restart operations.

## Proposed Solution: Development Server Testing Workflow

### Phase 1: Git Branch Management
- **Interface**: Admin panel with branch selection dropdown
- **Branches**: main, develop, feature branches (configurable list)
- **Current Branch Display**: Show currently checked out branch
- **Branch Switching**: Allow switching between branches before pull

### Phase 2: Development Server Management
- **Port Allocation**: 
  - Production: 5000 (current)
  - Development: 3001 (new)
- **Parallel Operation**: Both servers can run simultaneously
- **Resource Management**: Monitor memory/CPU usage of both servers

### Phase 3: Testing Interface
- **Visual Indicators**: 
  - Clear "DEVELOPMENT SERVER" banners/styling
  - Different color scheme for dev environment
  - Port number display in interface
- **Browser Management**:
  - Open dev server in new window/tab
  - Provide links to test key functionality
  - Side-by-side testing capability

### Phase 4: Production Deployment
- **Backup Strategy** (Options to evaluate):
  - **Option A**: File-based backup with git commit snapshots
  - **Option B**: Git tag-based versioning with rollback commits
- **Deployment Process**:
  1. Create backup/snapshot
  2. Deploy changes to production
  3. Provide rollback option if issues detected
  4. External restart mechanism (systemd or external script)

## Technical Implementation Requirements

### Git Integration
```perl
# Required functionality in Admin controller
- get_available_branches()
- get_current_branch()
- switch_branch($branch_name)
- pull_latest_changes($branch_name)
```

### Development Server Management
```perl
# Required functionality
- start_development_server($port)
- stop_development_server($port)
- get_development_server_status($port)
- get_development_server_url()
```

### Production Deployment
```perl
# Required functionality
- create_deployment_backup()
- deploy_to_production()
- rollback_deployment($backup_id)
- restart_production_server() # External process
```

## User Interface Requirements

### Branch Selection Interface
- Dropdown with available branches
- Current branch indicator
- "Pull Latest" button for selected branch
- Branch switching confirmation

### Development Server Interface
- Start/Stop development server controls
- Status indicator (running/stopped)
- "Open Development Server" button (new window)
- Resource usage display

### Testing Interface
- Clear development environment indicators
- Links to test key functionality
- Comparison tools (prod vs dev)
- "Deploy to Production" button (when testing complete)

### Production Deployment Interface
- Backup creation confirmation
- Deployment progress indicator
- Rollback option (if deployment issues)
- External restart instructions/automation

## Safety Features

### Backup and Rollback
- Automatic backup before any deployment
- Quick rollback mechanism
- Backup retention policy
- Deployment history tracking

### External Restart Mechanism
- Systemd service management (preferred)
- External script execution
- Health check verification
- Graceful fallback options

## Implementation Priority

1. **Phase 1**: Git branch management interface
2. **Phase 2**: Development server management
3. **Phase 3**: Visual indicators and testing interface
4. **Phase 4**: Production deployment with backup/rollback
5. **Phase 5**: External restart automation

## Questions for Next Session

1. **Backup Strategy**: Evaluate pros/cons of file-based vs git-based backup
2. **External Restart**: Determine best approach for production restart
3. **Branch Configuration**: Define which branches should be available
4. **Testing Automation**: Consider automated testing before deployment
5. **Monitoring**: Add deployment success/failure monitoring

## Files to Modify

- `Comserv/lib/Comserv/Controller/Admin.pm` - Add deployment workflow methods
- `Comserv/root/admin/` - Create new templates for deployment interface
- `Comserv/root/static/css/` - Add development environment styling
- `Comserv/config/` - Add deployment configuration files

## Success Criteria

- Safe code deployment without service interruption
- Clear distinction between development and production environments
- Reliable backup and rollback capabilities
- User-friendly interface for non-technical administrators
- Comprehensive logging and monitoring of deployment activities