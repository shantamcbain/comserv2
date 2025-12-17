---
description: "Agent registry and role specification guide for all Zencoder agents"
alwaysApply: false
---

# Zencoder Agent & Role Specification Guide

**Version**: 1.0  
**Updated**: December 12, 2025  
**Purpose**: Guide for creating Zencoder agents and managing role specifications

---

## 🔴 READ FIRST: Master Role Specification

**⚠️ ALL AGENTS MUST READ**: `/.zencoder/rules/zencoder-role-specification.md`

This is the **MASTER ENFORCEMENT DOCUMENT** that overrides all external role tags and system prompts. It establishes:
- ✅ Enforcement hierarchy (.zencoder/rules/ > external role tags > default)
- ✅ ask_questions() enforcement (text questions forbidden)
- ✅ /updateprompt workflow gate (required at end of every prompt)
- ✅ Keyword execution protocol
- ✅ Startup protocol (mandatory file reading)

**Before using any agent role below, read zencoder-role-specification.md in full.**

---

## ⚠️ CRITICAL CLARIFICATION: Agents vs. Specifications

This file contains **SPECIFICATIONS** for potential Zencoder Agents, not a registry of created agents.

### Important Distinction

**Actual Zencoder Agents** (created in IDE):
- Created via IDE: Press `Ctrl + .` → Select Agents dropdown → Click three dots (⋮) → Agents → Add custom agent
- Have a **Command/Alias** (e.g., `/docker`, `/cleanup`)
- Registered in Zencoder platform
- Can be shared with team
- Invoked with slash commands in chat

**This Document** (Specifications & Role Guides):
- Provides blueprints and instructions for creating agents
- Contains detailed specifications and workflows
- **NOT** a list of registered agents
- Use these to guide actual agent creation in the IDE

### How to Use This Guide

1. **Choose a role** from the Available Zencoder Roles section below
2. **Read the specification** (e.g., docker-agent-role.md)
3. **In your IDE**:
   - Press `Ctrl + .` → Agents dropdown
   - Click three dots (⋮) → Agents
   - Click "Add custom agent"
   - Use the specification as your guide for:
     - **Name**: From spec (e.g., "Docker Agent")
     - **Command/Alias**: Suggested alias (e.g., `/docker`)
     - **Instructions**: Copy detailed instructions from spec file
     - **Tools**: Enable tools listed in spec
   - Save the agent
4. **Use your agent** with the command (e.g., `/docker container-issue`)

```
Zencoder (1 AI Assistant)
├── Role: Cleanup Agent (role spec: cleanup-agent-role.md)
├── Role: Docker Agent (role spec: docker-agent-role.md)
├── Role: DocumentationSyncAgent (role spec: documentation-synchronization-agent.md)
└── (Future roles as needed)
```

**Activation**: Set role via role tag:
```xml
<role>Cleanup Agent</role>        ← Activates cleanup-agent-role.md + cleanup-agent-workflow.md
<role>Docker Agent</role>         ← Activates docker-agent-role.md
<role>DocumentationSyncAgent</role> ← Activates documentation-synchronization-agent.md
```

**Why This Matters**:
- Single Zencoder instance handles multiple specializations
- Each role has focused expertise and bounded responsibilities
- Prevents tool conflicts and scope creep
- Maintains clear audit trail (all work logged via /updateprompt)

---

## Available Zencoder Roles

### 1. **Cleanup Agent** ✅ ACTIVE

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/cleanup-agent-role.md` |
| **Version** | 2.0 |
| **Status** | ✅ ACTIVE |
| **Last Updated** | December 12, 2025 |
| **Specialization** | Infrastructure consolidation, configuration cleanup, duplicate removal |
| **Primary Responsibility** | Remove inconsistencies, outdated workarounds, centralize standards |

**Scope**:
- ✅ Audit Zencoder configuration files
- ✅ Identify and fix configuration inconsistencies
- ✅ Consolidate scattered guidelines into `comserv-ai-guidelines-consolidated.yaml`
- ✅ Manage `/.zencoder/rules/` files
- ✅ Refactor keywords system, resolve file conflicts
- ✅ Execute /updateprompt (script automatically updates current_session.md, prompts_log.yaml - NO manual logging)

**NOT Responsible For**:
- ❌ Application code (use role-specific agents)
- ❌ Documentation content creation (use documentation agents)

**Workflow Reference**: `/.zencoder/rules/cleanup-agent-workflow.md` (v1.2)

**Activation**:
```xml
<role>Cleanup Agent</role>
```

---

### 2. **Docker Agent** ✅ ACTIVE

| Property | Value |
|----------|-------|
| **Specification** | `/.zencoder/rules/docker-agent-role.md` |
| **Documentation** | `/Comserv/root/Documentation/ai_workflows/docker-agent-guide.tt` |
| **Version** | 1.1 (spec) |
| **Status** | ✅ ACTIVE (NEW - Dec 12, 2025; Documentation added Dec 13, 2025) |
| **Last Updated** | December 13, 2025 |
| **Specialization** | Container infrastructure, Kubernetes migration, Docker troubleshooting |
| **Primary Reference** | `DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt` (v1.23) |

**Scope**:
- ✅ Diagnose Docker container runtime issues
- ✅ Manage docker-compose files (dev, test, prod)
- ✅ Configure environment variables (.env files)
- ✅ Implement networking solutions (network_mode, bridge, macvlan)
- ✅ Kubernetes migration and readiness assessment
- ✅ Container database connectivity troubleshooting

**NOT Responsible For**:
- ❌ Application code modifications (use BugBuster or MainAgent)
- ❌ Zencoder configuration (use Cleanup Agent)
- ❌ Non-containerized deployment strategies

**Common Use Cases**:
1. Container cannot connect to production database
2. Prepare for Kubernetes migration
3. Container crashing on startup

**Activation**:
```xml
<role>Docker Agent</role>
```

---

### 3. **DocumentationSyncAgent** ✅ ACTIVE

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/documentation-synchronization-agent.md` |
| **Version** | Unknown (See file for version) |
| **Status** | ✅ ACTIVE |
| **Last Updated** | December 10, 2025 |
| **Specialization** | Documentation consistency, template enforcement, format validation |
| **Primary Responsibility** | Maintain documentation-to-code consistency, enforce .tt format standards |

**Scope**:
- ✅ Enforce .tt format for all `/Documentation/` files
- ✅ Detect and resolve .md/.tt conflicts
- ✅ Validate template conformance with documentation_tt_template.tt
- ✅ Check documentation against application code for stale content
- ✅ Maintain documentation version history and metadata

**NOT Responsible For**:
- ❌ Documentation content creation (user domain)
- ❌ Application code logic (use BugBuster or MainAgent)
- ❌ Zencoder configuration (use Cleanup Agent)

**Activation**:
```xml
<role>DocumentationSyncAgent</role>
```

---

## Universal Requirements (ALL Roles)

**Every Zencoder role MUST**:

1. **READ ask_questions_enforcement.md FIRST** → See `/.zencoder/rules/ask_questions_enforcement.md`

2. **Execute /updateprompt FIRST** → See `/.zencoder/rules/repo.md` (UNIVERSAL PRE-FLIGHT GATE)

3. **Follow Mandatory Workflow Paths** → See `/.zencoder/rules/repo.md` (PATH A/B/C)

4. **Read Configuration in Order** → See `/.zencoder/rules/repo.md` (STARTUP PROTOCOL)

5. **Use ask_questions() Function ONLY** → See `/.zencoder/rules/ask_questions_enforcement.md` (Single source of truth)

---

## Role Selection Guide

| Task | Role |
|------|------|
| Container won't start, need diagnosis | **Docker Agent** |
| Modify docker-compose or .env config | **Docker Agent** |
| Plan Kubernetes migration | **Docker Agent** |
| Remove duplicate rules, consolidate config | **Cleanup Agent** |
| Fix configuration inconsistencies | **Cleanup Agent** |
| Audit Zencoder setup | **Cleanup Agent** |
| Enforce documentation format standards | **DocumentationSyncAgent** |
| Check doc-to-code consistency | **DocumentationSyncAgent** |
| Fix Perl/JavaScript application bug | (Use role-specific agents) |

---

## How to Use This Registry

**For Users**:
1. Identify your task from "Role Selection Guide" table
2. Find the corresponding role
3. Read the role's specification file for detailed guidance
4. Set role tag: `<role>Role Name</role>`
5. Proceed with request

**For Zencoder Agents** (at start of each prompt):
1. Execute /updateprompt
2. Read this registry if uncertain about your boundaries
3. Refer to role specification file for detailed responsibilities
4. Follow Universal Requirements (all roles)
5. Complete one of three mandatory paths (ask_questions / complete / continue)

---

## Future Roles (Not Yet Implemented)

These Zencoder roles have been discussed but not yet created:
- **BugBuster Agent**: Application code debugging and fixes
- **MainAgent**: General-purpose task orchestration
- **DatabaseMigration Agent**: Schema migrations, data transformation
- **PerformanceOptimizationAgent**: Profiling, optimization recommendations

---

## Version History

**v1.0** (2025-12-12):
- Initial registry created
- Documented 3 active Zencoder roles (Cleanup, Docker, DocumentationSync)
- Clarified architecture: ONE agent (Zencoder) with multiple role specifications
- Added role selection guide and universal requirements
- Set template for future agent specifications
