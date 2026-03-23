`# Application Naming Standards for Comserv

**Version**: 1.0.0  
**Date**: 2025-12-19  
**Purpose**: Establish clear naming conventions for collaborative development  
**Next Session**: Implementation and integration into codebase documentation  

## Problem Statement

Our application has multiple functional areas (inventory, project, todo, backup, file, software update) that interact with Catalyst framework components (Controller, Model, View). Without clear naming standards, communication becomes ambiguous and development coordination suffers.

## Industry Standard Naming Conventions

### Architectural Layer Terminology (MVC Pattern)

**Catalyst Framework Standards:**
- **Controller**: Application logic handlers (`/lib/Comserv/Controller/`)
- **Model**: Data access and business logic (`/lib/Comserv/Model/`)  
- **View**: Template presentation layer (`/root/` - .tt files)
- **Util**: Shared utility functions (`/lib/Comserv/Util/`)

### Business Domain Naming (Functional Areas)

**Primary Business Domains** (Based on existing application structure):
- **Project Management** - Project planning, tracking, documentation
- **Inventory Management** - Asset and resource tracking
- **Todo Management** - Task and workflow management  
- **Backup Management** - Data backup and recovery operations
- **File Management** - File system operations and organization
- **Software Management** - Application updates and maintenance

### Component Interaction Terminology

**Standard Interaction Patterns:**
- **Service Layer** - Business logic coordination between domains
- **Repository Pattern** - Data access abstraction  
- **Facade Pattern** - Simplified interfaces for complex subsystems
- **Integration Points** - Where domains interact with each other

## Proposed Naming Convention System

### 1. **Domain-Driven Design (DDD) Approach**

**Format**: `[Domain].[Component].[Function]`

**Examples:**
```
Project.Controller.List    → ProjectController with list action
Backup.Util.Manager       → BackupManager utility class  
File.Model.Storage        → FileStorage model
Todo.Service.Workflow     → TodoWorkflow service layer
```

### 2. **Catalyst-Specific Implementation**

**Controllers**: `[Domain]Controller`
```
ProjectController.pm     → /lib/Comserv/Controller/Project.pm
BackupController.pm      → /lib/Comserv/Controller/Admin/Backup.pm  
FileController.pm        → /lib/Comserv/Controller/File.pm
```

**Models**: `[Domain]Model` or `[Domain][Entity]`
```
ProjectModel.pm          → /lib/Comserv/Model/Project.pm
BackupConfig.pm          → /lib/Comserv/Model/BackupConfig.pm
FileStorage.pm           → /lib/Comserv/Model/File.pm
```

**Utilities**: `[Domain]Manager` or `[Domain]Util`
```
BackupManager.pm         → /lib/Comserv/Util/BackupManager.pm
ProjectManager.pm        → /lib/Comserv/Util/ProjectManager.pm
FileSystemUtil.pm        → /lib/Comserv/Util/FileSystem.pm
```

**Templates**: `[domain]/[action].tt`
```
project/list.tt          → Project listing page
backup/index.tt          → Backup management interface
file/upload.tt           → File upload interface
```

### 3. **Git Branch Naming Standards**

**Format**: `[type]/[domain]-[feature]`

**Types:**
- `feature/` - New functionality  
- `bugfix/` - Bug corrections
- `refactor/` - Code restructuring
- `docs/` - Documentation updates

**Examples:**
```
feature/backup-manager-refactor
bugfix/file-upload-validation
refactor/project-controller-cleanup
docs/api-naming-standards
```

## Communication Protocol Standards

### 1. **Reference Format in Conversations**

**When discussing components:**
- "The Backup Controller" → `Controller::Admin::Backup`  
- "File management system" → `File Domain` (all file-related components)
- "Project model logic" → `Model::Project`  
- "BackupManager utility" → `Util::BackupManager`

### 2. **Issue/Task Naming**

**Format**: `[DOMAIN] - [Component] - [Description]`

**Examples:**
```
BACKUP - Controller - Add file restoration endpoint
FILE - Model - Implement storage validation  
PROJECT - View - Update listing template layout
SYSTEM - Util - Create shared logger functionality
```

### 3. **Documentation Structure**

**Format**: `[Domain][Component]Documentation.tt` (CamelCase)

**Examples:**
```
BackupControllerAPI.tt       → Backup controller endpoints
FileManagerIntegration.tt    → File management system docs  
ProjectModelSchema.tt        → Project data model documentation
```

**Configuration Files**: `[Component]Config.json` (CamelCase)

**Examples:**
```
DocumentationConfig.json     → Documentation system configuration
DatabaseConfig.json          → Database configuration
ApplicationConfig.json       → Application-wide configuration
```

## Current Application Domain Mapping

### Identified Domains in Comserv:

**Core Business Domains:**
1. **Admin** - System administration (`/admin/` routes)
2. **Project** - Project management functionality  
3. **Todo** - Task and workflow management
4. **Backup** - Data backup and recovery
5. **File** - File system management
6. **Documentation** - System documentation
7. **Navigation** - UI navigation components

**Support Domains:**
1. **Auth** - Authentication and authorization
2. **Config** - Configuration management  
3. **Logging** - Application logging
4. **Git** - Version control integration

## Implementation Roadmap for Next Session

### Phase 1: Documentation Integration (1-2 operations)
- [ ] Update AI_DEVELOPMENT_GUIDELINES.md with naming standards reference
- [ ] Create domain mapping document for existing codebase

### Phase 2: Codebase Analysis (3-5 operations)  
- [ ] Scan existing controllers and identify current naming patterns
- [ ] Map existing utilities to proposed naming conventions
- [ ] Document deviations and required refactoring

### Phase 3: Standard Application (5-8 operations)
- [ ] Create naming validation checklist for development
- [ ] Update session tracking to use domain.component format
- [ ] Apply standards to current File Manager enhancement plan

### Phase 4: Communication Protocol (2-3 operations)
- [ ] Update development planning templates with domain references
- [ ] Create quick-reference guide for AI-human communication
- [ ] Test naming system with specific implementation examples

## Success Criteria

**Clear Communication**: 
- No ambiguity when referencing system components
- Consistent terminology across documentation and conversations  
- Easy identification of component interactions

**Development Efficiency:**
- Faster code location and understanding
- Reduced onboarding time for new team members
- Consistent file organization and naming

**Scalability:**
- Standards support application growth
- Clear patterns for adding new domains
- Maintainable naming as complexity increases

## Next Session Priority

**IMMEDIATE TASK**: Apply naming standards to File Manager Enhancement Plan
**FOCUS**: Use this document as foundation to clarify File Domain components and their interactions with Backup Domain

**Files Ready for Next Session:**
- This naming standards document (complete)
- Current application domain mapping (needs implementation)
- File Manager enhancement plan (needs naming standard application)

---

*This document establishes the foundation for clear communication and collaborative development. Implementation begins next session.*