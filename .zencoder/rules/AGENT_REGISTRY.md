 ---
description: "Agent registry and role specification guide for all Zencoder agents"
alwaysApply: false
---

# Zencoder Agent & Role Specification Guide

**Version**: 2.2  
**Updated**: January 2, 2026  
**Purpose**: Guide for using consolidated Zencoder agent specifications (all agents in coding-standards.yaml)

**🔴 CRITICAL UPDATE (Jan 2, 2026)**:
- ✅ **ALL 9 agents consolidated into single source of truth**: `/.zencoder/coding-standards.yaml`
- ✅ **MainAgent added**: General-purpose application development agent (v1.0)
- ✅ **Individual .md agent files deprecated**: `docker-agent-role.md`, `cleanup-agent-role.md`, etc. are reference-only (not active)
- ✅ **Agent specifications**: Read from `coding-standards.yaml` lines 443-1187 (agents section)

---

## 🔴 READ FIRST: Consolidated Coding Standards

**⚠️ ALL AGENTS MUST READ**: `/.zencoder/coding-standards.yaml` (THIS IS THE MASTER SOURCE NOW)

This file contains:
- ✅ GLOBAL RULES (Rules 1-6): ask_questions(), /updateprompt, file tools, startup protocol, execution patterns, conflict resolution
- ✅ ALL 9 AGENT SPECIFICATIONS: Complete role definitions with responsibilities, constraints, workflows, tools, integrations
- ✅ KEYWORDS section: Consolidated keyword definitions (/chathandoff, /newsession, /validatett)
- ✅ Enforcement hierarchy: coding-standards.yaml > external role tags > defaults

**Enforcement Hierarchy**:
```
Priority 1 (HIGHEST):  /.zencoder/coding-standards.yaml - MASTER SOURCE
Priority 2:           Agent-specific sections within coding-standards.yaml  
Priority 3:           External system role tags (ignored if conflict with Priority 1)
Priority 4:           Default behavior/conventions
```

**Before using any agent, read the GLOBAL RULES section in coding-standards.yaml (lines 53-437).**

---

## 📊 File Structure Reference

**Single Source of Truth** - All workflow files in `/Comserv/root/Documentation/`:

| File | Purpose | Type | Agent Access |
|------|---------|------|---------------|
| `MASTER_PLAN_COORDINATION.tt` | 15 plans, 18 features, priorities (THE document) | .tt (application) | Read + Update |
| `DailyPlans/Daily_Plans-YYYY-MM-DD.tt` | Daily workflows, plan vs. accomplishment | .tt (application) | Read only |
| `session_history/current_session.md` | Chat history, work completed | .md (tracking) | Read only |
| `session_history/audit_logs/*.md` | Daily audits (reference only, not displayed) | .md (tracking) | Create + Read |

**KEY RULE**: Agents read FROM and UPDATE .tt files. No parallel .md universe of duplicate documents.

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

**Activation**: Set role via role tag - ALL SPECIFICATIONS IN coding-standards.yaml:
```xml
<role>Main Agent</role>                  ← Activates general-purpose development (coding-standards.yaml:1093)
<role>Cleanup Agent</role>               ← Activates configuration cleanup (coding-standards.yaml:444)
<role>Docker Agent</role>                ← Activates container infrastructure (coding-standards.yaml:521)
<role>Master Plan Manager Agent</role>   ← Activates master plan viewing/updates (coding-standards.yaml:835)
<role>Daily Audit Agent</role>           ← Activates session auditing (coding-standards.yaml:673)
<role>Master Plan Updater Agent</role>   ← Activates master plan coordination (coding-standards.yaml:591)
<role>Daily Plan Automator Agent</role>  ← Activates workflow automation (coding-standards.yaml:753)
<role>DocumentationSyncAgent</role>      ← Activates documentation consistency (coding-standards.yaml:1004)
```

**Why This Matters**:
- Single consolidated YAML file is the source of truth for all agents
- Each agent has focused expertise and bounded responsibilities
- Prevents tool conflicts and scope creep
- Maintains clear audit trail (all work logged via /updateprompt to prompts_log.yaml)

---

## Available Zencoder Agents (All 9 Consolidated in coding-standards.yaml)

### 0. **Main Agent** ✅ ACTIVE (NEW - Jan 2, 2026)

| Property | Value |
|----------|-------|
| **IDE Name** | `Main Agent` |
| **Shortcut** | `/main` |
| **Role Specification** | `/.zencoder/coding-standards.yaml` (lines 1093-1187) |
| **Version** | 1.0 |
| **Status** | ✅ ACTIVE - General-purpose development agent |
| **Last Updated** | January 2, 2026 |
| **Specialization** | Application development, bug fixes, feature implementation, testing |
| **Primary Responsibility** | Implement features, fix bugs, write tests, follow Catalyst framework patterns and Comserv conventions |

**Scope**:
- ✅ Implement new features and modifications
- ✅ Debug and fix issues in application code (controllers, models, views, utilities)
- ✅ Write and run unit tests, integration tests, validation
- ✅ Follow Catalyst framework patterns and Comserv conventions
- ✅ Execute /updateprompt logging and session tracking
- ✅ Enforce ask_questions() function for user input
- ✅ Participate in /chathandoff and /newsession workflows

**NOT Responsible For**:
- ❌ Zencoder configuration (use Cleanup Agent)
- ❌ Container infrastructure (use Docker Agent)
- ❌ Documentation sync (use DocumentationSyncAgent)

**Invocation**:
```
/main               ← Use this command (when MainAgent is registered as IDE agent)
```

**Activation** (via role tag):
```xml
<role>Main Agent</role>
```

---

### 1. **Cleanup Agent** ✅ ACTIVE (Consolidated)

| Property | Value |
|----------|-------|
| **Role Specification** | `/.zencoder/coding-standards.yaml` (lines 444-519) |
| **Version** | 2.1 (consolidated 2025-12-31) |
| **Status** | ✅ ACTIVE - Primary cleanup agent |
| **Last Updated** | December 31, 2025 |
| **Specialization** | Infrastructure consolidation, configuration cleanup, duplicate removal |
| **Primary Responsibility** | Remove inconsistencies, outdated workarounds, centralize standards in Zencoder configuration |

**Activation** (via role tag):
```xml
<role>Cleanup Agent</role>
```

---

### 2. **Docker Agent** ✅ ACTIVE

| Property | Value |
|----------|-------|
| **Role Specification** | `/.zencoder/coding-standards.yaml` (lines 521-588) |
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
| **Extension** | `/.zencoder/rules/documentation-sync-agent-extension.md` (NEW) |
| **Version** | 1.0 base + 1.0 extension |
| **Status** | ✅ ACTIVE |
| **Last Updated** | December 28, 2025 (Extension added) |
| **Specialization** | Documentation consistency, template enforcement, format validation, **documentation updates** |
| **Primary Responsibility** | Maintain documentation-to-code consistency, enforce .tt format standards, **update docs with code changes** |

**Scope** (Base Agent):
- ✅ Enforce .tt format for all `/Documentation/` files
- ✅ Detect and resolve .md/.tt conflicts
- ✅ Validate template conformance with documentation_tt_template.tt
- ✅ Check documentation against application code for stale content
- ✅ Maintain documentation version history and metadata

**NEW Scope** (Extension - Dec 28):
- ✅ **Receive doc update requests from /daily-audit agent**
- ✅ **Update specified .tt files with code change summaries**
- ✅ **Increment documentation version numbers**
- ✅ **Update last_updated timestamps**
- ✅ **Call /update-master-plan agent** when updates complete

**NOT Responsible For**:
- ❌ Documentation content creation (user domain)
- ❌ Application code logic (use BugBuster or MainAgent)
- ❌ Zencoder configuration (use Cleanup Agent)

**When Called by /daily-audit**:
- Use BOTH: `documentation-synchronization-agent.md` + `documentation-sync-agent-extension.md`
- Sequence: Read audit request → Update .tt files → Call /update-master-plan

**Activation**:
```xml
<role>DocumentationSyncAgent</role>
```

---

### 4. **Master Plan Manager Agent** ✅ ACTIVE (Standalone)

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/master-plan-manager-agent-role.md` |
| **Version** | 1.0 |
| **Status** | ✅ ACTIVE (NEW Dec 28, 2025) |
| **Last Updated** | December 28, 2025 |
| **Specialization** | Master plan viewing, updating, querying; project coordination |
| **Primary Responsibility** | View master plan dashboard, update with audit results, search/query plans |
| **Command/Alias** | `/master-plan` |

**Scope**:
- ✅ View master plan overview (read-only dashboard display)
- ✅ Update master plan with audit results (version increment, activity logging)
- ✅ Query/search plans by name, status, priority, or dependencies
- ✅ Display 15 active plans + 18 features + 47 controllers inventory
- ✅ Show recent activity log and next steps
- ✅ Support both standalone invocation AND workflow integration

**NOT Responsible For**:
- ❌ Creating audit entries (Daily Audit Agent's job)
- ❌ Modifying documentation files (DocumentationSyncAgent's job)
- ❌ Modifying application code (use BugBuster or MainAgent)

**Invocation**:
```bash
/master-plan                    # View mode (default)
/master-plan view              # Explicit view
/master-plan update [audit]    # Update with audit data
/master-plan query [term]      # Search/query plans
```

**Workflow Chain Position** (can also be standalone):
```
/daily-audit → DocumentationSyncAgent → /master-plan update
```

**Activation**:
```xml
<role>Master Plan Manager Agent</role>
```

---

### 5. **Daily Audit Agent** ✅ NEW (December 28, 2025)

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/daily-audit-agent-role.md` |
| **Version** | 1.0 |
| **Status** | ✅ NEW - Ready for deployment |
| **Created** | December 28, 2025 |
| **Specialization** | Session auditing, code change documentation, documentation gap identification |
| **Primary Responsibility** | Create daily audit entries from session history; identify which .tt files need updates |

**Scope**:
- ✅ Read `current_session.md` and extract latest work
- ✅ Create audit entries in `daily_audit_log.md` (append mode)
- ✅ Document code changes, issues resolved, successes achieved
- ✅ Map code file changes to documentation files needing updates
- ✅ Ask user confirmation before calling DocumentationSyncAgent
- ✅ Trigger documentation sync workflow when approved

**NOT Responsible For**:
- ❌ Modifying documentation files (DocumentationSyncAgent's job)
- ❌ Updating master plan (Master Plan Updater's job)
- ❌ Creating code changes (audit only)

**Workflow Chain**:
```
/daily-audit 
  → creates audit_log.md entry
  → identifies docs needing updates
  → asks user: "Update these docs?"
  → calls DocumentationSyncAgent (if approved)
```

**Activation**:
```xml
<role>Daily Audit Agent</role>
```

**Command**:
```
/daily-audit
```

---

### 6. **Master Plan Updater Agent** ✅ ACTIVE (Workflow Component)

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/master-plan-updater-agent-role.md` |
| **Version** | 1.0 |
| **Status** | ✅ ACTIVE (Component of Master Plan Manager Agent) |
| **Created** | December 28, 2025 |
| **Specialization** | Master plan coordination, version management, next steps prioritization |
| **Primary Responsibility** | Internal component: Update `MASTER_PLAN_COORDINATION.tt` with audit results (called by Master Plan Manager Agent) |
| **Note** | Use **Master Plan Manager Agent** instead for standalone invocation |

**Scope**:
- ✅ Receive audit + documentation sync results from DocumentationSyncAgent
- ✅ Update MASTER_PLAN_COORDINATION.tt metadata (version, last_updated, status)
- ✅ Add Recent Activity entries documenting daily work
- ✅ Update Next Steps section with priorities from audit
- ✅ Increment version numbers (0.XX → 0.XX+1)
- ✅ Validate HTML/TT syntax after updates

**NOT Responsible For**:
- ❌ Creating audit entries (Daily Audit Agent's job)
- ❌ Modifying documentation files (DocumentationSyncAgent's job)
- ❌ Modifying code (audit reference only)

**Workflow Chain** (called by):
```
DocumentationSyncAgent 
  → /update-master-plan 
  → updates MASTER_PLAN_COORDINATION.tt
  → completes audit chain
```

**Activation**:
```xml
<role>Master Plan Updater Agent</role>
```

**Command**:
```
/update-master-plan
```

---

### 7. **Daily Plan Automator Agent** ✅ NEW (December 29, 2025)

| Property | Value |
|----------|-------|
| **File** | `/.zencoder/rules/daily-plan-automator-role.md` |
| **Version** | 1.0 |
| **Status** | ✅ NEW - First execution Dec 29, 2025 |
| **Created** | December 29, 2025 |
| **Specialization** | Daily workflow automation, master plan updates, daily plan generation |
| **Primary Responsibility** | Execute complete daily plan automator workflow (read master plan → create audit → update master plan → generate daily plans) |
| **Command/Alias** | `/daily-plan-auto` or manual execution |

**Scope**:
- ✅ **STEP 1**: Read and analyze MASTER_PLAN_COORDINATION.tt (current progress)
- ✅ **STEP 2**: Review previous 7 days of daily plans
- ✅ **STEP 3**: Read current session history from current_session.md
- ✅ **STEP 4**: Create today's audit file (audit_YYYY-MM-DD.md)
- 🔴 **STEP 5**: Execute `/chathandoff` CRITICAL CHECKPOINT (prevents token exhaustion)
- ✅ **STEP 6** (new chat): Update MASTER_PLAN_COORDINATION.tt with progress, version bump, link update
- ✅ **STEP 7** (new chat): Verify and generate daily plans for next 7 days
- ✅ **STEP 8** (new chat): Execute final `/newsession`

**CRITICAL**: Includes mandatory `/chathandoff` checkpoint after Step 4 to prevent hanging/timeout during large master plan updates

**Execution Timing**:
- **Start of day**: First chat - generates daily plans for upcoming days
- **During day**: After task completion - keeps daily plan current
- **End of day**: Final run - prepares for next working day

**NOT Responsible For**:
- ❌ Creating code changes (audit only, reference for updates)
- ❌ Modifying application code (use BugBuster or MainAgent)
- ❌ Interactive coding tasks (use role-specific agents)

**Resource Management**:
- ✅ Token-intensive workflow split across 2 chat sessions
- ✅ First chat: Steps 1-4 (audit creation)
- 🔄 Checkpoint: `/chathandoff` to start fresh session
- ✅ Second chat: Steps 6-8 (master plan + daily plans)
- ✅ Final: `/newsession` archives session

**Workflow Chain**:
```
[Start] → STEP 1-4 (first chat) 
  → /chathandoff (MANDATORY checkpoint)
  → STEP 6-8 (second chat) 
  → /newsession (archives session)
  → [Ready for next working day]
```

**Why /chathandoff is Critical**:
- MASTER_PLAN_COORDINATION.tt is 1900+ lines
- Reading + analyzing + updating = large token consumption
- Without checkpoint: AI runs out of tokens mid-update and hangs
- With checkpoint: New chat session starts fresh with clean context
- Prevents timeout, allows completion without IDE crashes

**Activation**:
```xml
<role>Daily Plan Automator</role>
```

**User Workflow**:
1. Start of day: Run Daily Plan Automator (first chat) → See `/chathandoff` prompt
2. Respond to `/chathandoff` → Starts new chat (second chat)
3. Second chat completes master plan updates + daily plan generation
4. At end of chat: User manually executes `/newsession` if session is complete
5. Next working day: Repeat from step 1

---

## Universal Requirements (ALL Roles)

**Every Zencoder role MUST**:

1. **READ Rule 1 FIRST** → See `coding-standards.yaml` Rule 1 (ask_questions() enforcement)

2. **Execute /updateprompt FIRST** → See `coding-standards.yaml` Rule 2 (UNIVERSAL WORKFLOW GATE)

3. **Follow Mandatory Workflow Paths** → See `coding-standards.yaml` Rule 1 Execution Sequence (WORK→UPDATEPROMPT→ASK→ACT→END)

4. **Read Global Rules in Order** → See `coding-standards.yaml` lines 53-437 (STARTUP PROTOCOL)

5. **Use ask_questions() Function ONLY** → See `coding-standards.yaml` Rule 1 (Single source of truth)

---

## Role Selection Guide

| Task | Role |
|------|------|
| **View master plan + all 15 plans overview** | **Master Plan Manager Agent** (`/master-plan`) |
| **Search/query plans by name, status, priority** | **Master Plan Manager Agent** (`/master-plan query`) |
| **Update master plan with daily work** | **Master Plan Manager Agent** (`/master-plan update`) |
| Container won't start, need diagnosis | **Docker Agent** |
| Modify docker-compose or .env config | **Docker Agent** |
| Plan Kubernetes migration | **Docker Agent** |
| Remove duplicate rules, consolidate config | **Cleanup Agent** |
| Fix configuration inconsistencies | **Cleanup Agent** |
| Audit Zencoder setup | **Cleanup Agent** |
| **Create daily audit of code changes** | **Daily Audit Agent** (`/daily-audit`) |
| **Audit session work + identify doc updates** | **Daily Audit Agent** (`/daily-audit`) |
| Enforce documentation format standards | **DocumentationSyncAgent** |
| Check doc-to-code consistency | **DocumentationSyncAgent** |
| **Update documentation with code changes** | **DocumentationSyncAgent** (with extension) |
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
- **DatabaseMigration Agent**: Schema migrations, data transformation
- **PerformanceOptimizationAgent**: Profiling, optimization recommendations

**Note**: MainAgent (v1.0) is now IMPLEMENTED and consolidated in `coding-standards.yaml` (lines 1093-1187). Use for general-purpose application development tasks.

---

## Version History

**v1.0** (2025-12-12):
- Initial registry created
- Documented 3 active Zencoder roles (Cleanup, Docker, DocumentationSync)
- Clarified architecture: ONE agent (Zencoder) with multiple role specifications
- Added role selection guide and universal requirements
- Set template for future agent specifications

**v2.0** (2025-12-28):
- **Agent chaining workflow added** for daily auditing + documentation updates
- Added Daily Audit Agent (v1.0) - session auditing + documentation gap identification
- Added Master Plan Updater Agent (v1.0) - master plan coordination + version management
- Extended DocumentationSyncAgent with file update capability (v1.0 extension)
- Created three-agent chain: `/daily-audit` → `DocumentationSyncAgent` → `/update-master-plan`
- Prevents IDE crashes via resource-constrained lightweight agent design
- Updated Role Selection Guide with new audit + documentation update tasks
- Enables daily master plan coordination with minimal resource overhead

**v2.1** (2025-12-28):
- **Master Plan Manager Agent ADDED** (v1.0) - Standalone agent for viewing, updating, querying master plan
- New command: `/master-plan` - now accessible as primary agent (not just workflow component)
- Supports 3 modes: view (dashboard display), update (from audit), query (search/filter)
- Restructured: Master Plan Updater Agent now component of Manager Agent
- Added master plan tasks to Role Selection Guide
- Master Plan now accessible as independent agent invocation

**v2.2** (2026-01-02):
- **MainAgent CONSOLIDATED** into `coding-standards.yaml` (v1.0) - General-purpose application development
- Removed MainAgent from "Future Roles" section
- Updated workflow: /updateprompt as FIRST action, PATH A/B/C execution pattern enforced
- Updated constraints: Mark /updateprompt, ask_questions(), /chathandoff as MANDATORY
- All 9 agents now consolidated into single source of truth (`coding-standards.yaml` lines 443-1187)

**v2.3** (2026-01-03):
- **CLEANUP PASS**: Removed references to deleted agent specification files (docker-agent-role.md, cleanup-agent-role.md, etc.)
- Updated file references to point exclusively to `coding-standards.yaml` master source
- Verified no broken file references remain in registry
- Single source of truth: `/.zencoder/coding-standards.yaml` (agents section lines 443-1187)
- All agent specs consolidated; individual .md files archived in session_history/zencoder_rules_archive/
