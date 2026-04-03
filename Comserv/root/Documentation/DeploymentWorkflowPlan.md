# Deployment Workflow Plan

**Version:** 1.0  
**Last Updated:** 2025-01-10  
**Status:** Planning Phase

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