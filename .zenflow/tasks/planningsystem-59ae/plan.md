# Planning System Audit & Enhancement

## Configuration
- **Artifacts Path**: `.zenflow/tasks/planningsystem-59ae`

---

## Audit Findings (2026-03-20)

### Current State Summary

**Two parallel planning systems exist — both still active:**

#### 1. Text-Based Planning (being phased out)
- **Files**: `Documentation/DailyPlans/DailyPlans-YYYY-MM-DD.tt` (20+ dated files, Dec 2025 – Jan 2026)
- **Access**: Served via `Documentation.pm::daily_plan` at `/Documentation/DailyPlan`
- **Template**: `admin/documentation/DailyPlan.tt` — large multi-tab dashboard with hardcoded weekly priorities, master plan links, resource context, and a Zencoder prompt tab
- **Registered in**: `DocumentationConfig.json` with `site: "all"`, roles: admin/developer/devops
- **Problem**: `site: "all"` means ALL sites default to viewing CSC planning — no SiteName filtering exists
- **Latency**: Last dated file is `Daily_Plans-2026-01-18.tt` — ~2 months behind as of March 2026

#### 2. DB-Driven Planning (the target model)
- **Controller**: `Comserv::Controller::Admin::PlanManagement` at `/admin/plan/list`
- **AI integration**: `Comserv::Controller::AIPlanning` — attaches Zenflow tasks to DB plans
- **DB Result classes**: `DailyPlan.pm`, `DailyPlanProject.pm`, `DailyPlanEntry.pm`, `PlanSystemMapping.pm`, `PlanAudit.pm` — all exist in Schema/Ency/Result/
- **Schema**: `dailyplan` table with `sitename`, `allowed_roles` (JSON), `status`, `priority`, dates
- **Status**: Controller exists and operational but no SiteName-based filtering was implemented

### Branches Identified (relevant to planning)
- `main` — primary branch (current worktree)
- `cssthemes-9195` — theme work (recently merged into main)
- `membership-1304` — membership/roles work (relevant to role-based access)
- `api-bc05` — API work
- `bmaster-f0fd` — BMaster beekeeping (separate domain)
- `aichatsystem-ef4e` — AI chat system

### Key Issues Found
1. **No SiteName access gate on `/Documentation/DailyPlan`** — any authenticated user on any site reaches text-based CSC planning
2. **`PlanManagement::begin` had no site visibility context** — all admins could query all plans
3. **Documentation 2 months stale** — last update Jan 18, 2026; DB model should replace this
4. **`next;` skip with `TEMPORARY` comment in Documentation index** — role/site filtering disabled globally

---

## Changes Implemented (Step: Implementation)

### `Comserv/lib/Comserv/Controller/Documentation.pm`
- Added access gate at the top of `daily_plan` sub:
  - **Non-CSC sites**: redirected to `/admin/plan/list` (DB-driven view)
  - **CSC sites**: role check — only admin/developer/devops can access; others get 403 error page

### `Comserv/lib/Comserv/Controller/Admin/PlanManagement.pm`
- `begin` action: computes `is_csc_admin` and `plan_sitename` stash vars
  - CSC admin = SiteName is CSC AND role includes `admin`
  - Non-CSC = restricted to own site only
- `list` action: SiteName-based filtering
  - CSC admin with no filter → sees all plans across all sites
  - CSC admin with `?sitename=X` filter → sees only site X plans
  - Non-CSC admin/developer → sees only their own site's plans
- `details` action: enforces plan ownership — non-CSC users get 403 if they request a plan from another site

---

## Workflow Steps

### [x] Step: Implementation
<!-- chat-id: 98905a1f-d799-4381-8706-52e0fda8158b -->

Audit complete. Implemented SiteName-based access controls:
- CSC-only access gate on text-based DailyPlan (`/Documentation/DailyPlan`)
- Non-CSC sites redirected to DB-driven plan view (`/admin/plan/list`)
- CSC admins can see all sites with optional filter; others see only their own site
- Verification: `perl -cw Comserv/script/comserv_server.pl` → syntax OK

**Session 4 fixes (commits 4ce0befe, 26222fe6):**
- `DailyPlan.tt` line 555: Fixed TT parse error `{-desc => 'created_at'}` → `'created_at DESC'`
- `Root.pm auto`: Added error logging to UserSiteRole eval block; now logs success/fail for site-specific admin detection
- `Documentation.pm daily_plan`: Access check now uses `$c->stash->{is_admin}` (Root::auto canonical) OR session roles — site-specific admins no longer bounced to login
- `Todo.pm begin`: Same fix — checks `$c->stash->{is_admin}` first; redirects to login (not home) on deny
- `PlanManagement.pm begin`: Same fix; also uses `$c->stash->{SiteName}` (canonical) for `is_csc_admin` detection
- **NOTE:** Perl changes require server restart at port 3001. Template fixes (DailyPlan.tt) take effect immediately.

**Session 2 fixes (commit b99522ec):**
- `Todo.pm`: Fixed case-sensitive role check → `lc($_ ) eq 'admin'`
- `User.pm do_login`: Now merges `UserSiteRole` table roles for the current site into session at login. Site-specific admins (e.g., Shanta admin) now correctly get `is_admin = 1` in session.
- `pagetop.tt`: `is_admin` now prefers `c.stash.is_admin` (Root::auto's canonical value) over the old case-sensitive session roles grep. Welcome message now shows `first_name` (or username) for any logged-in user instead of falling back to "Guest".
- **Action required**: User must log out and log back in to get the merged site roles in session.

**Session 3 fixes (commit 6d88be52):**
- `PlanManagement.pm create`: Fixed `catalyst_detach` error — `$c->detach` was inside `Try::Tiny` and caught by catch. Refactored to handle GET (renders form) vs POST (saves plan). On success, redirects to `/admin/plan/list`. Re-throws Catalyst exceptions inside catch.
- `admin/plan/create.tt`: New plan creation form template with name, description, status, priority, start/due dates. Pre-fills sitename badge. Errors shown inline.
- Added `'normal'` role to planning/todo access: `PlanManagement::begin`, `Todo.pm::begin`, and `can_plan` in `TopDropListLogin.tt`. Admin-created users have global role `'normal'` — they now get planning access.
- `TopDropListLogin.tt`: Planning header link now only shows as a clickable link when `can_plan` is true. Non-can_plan users see a non-clickable "Planning" label (prevents redirect-to-home when clicking a broken link).
- Merged all fixes to worktree branch (port 4001).

**Session 5 fixes (commits 90cfcdbf, 667746c7):**
- `Documentation.pm daily_plan`: Fixed planning_projects display — split outer eval into separate blocks; added `parent_id => undef` filter directly in DBIC SQL query (was filtering in Perl loop after fetching all 170 projects); added debug logging for project count. An orphan-plan eval failure can no longer block the project list from rendering.
- Fixed 6 projects with numeric sitename=1 in DB → set to `CSC` (previous session, root cause fix).
- Created 15 ordered planning todos (record_ids 502–516) in DB across phases 186–190 of Planning System project, with proper priority ordering and `blocked_by_todo_id` dependencies.
- `Log.pm create_log`: Redirect to `/log` after successful log save (was redirecting to `/todo/details`).
- `log_form.tt`: Fixed `field_name='project_id'` in project_list.tt include (was defaulting to `parent_id` — log project was never saved); normalized status comparison to handle both numeric (1/2/3) and string (NEW/IN PROGRESS/DONE/In-Process/Completed) status values from DB.
- **Server restart required** for Perl changes to take effect.

**Session 6 fixes (commits 1268cf6f, 1d9e7b54, d787848b — already merged to main):**
- `projectdetails.tt`: Replaced partial field list with complete table showing all 17 project fields (id, record_id, sitename, parent_id, posted_by, group, date_posted, etc.)
- `log_form.tt`: Added `Pending` → option value=1 (NEW) mapping; handles all known DB status strings
- `addtodo.tt`: Added `Pending`, `In-Process`, `Completed` string-status matching for correct pre-selection
- `Log.pm`: Fixed `form_data` key from `parent_id` to `project_id`; `create_log` error path now reads `project_id` from form (with `parent_id` fallback)
- **DB data fix**: Project id=6 "Navigation" had `sitename='1'` → corrected to `sitename='CSC'` (eliminates "1" button in Planning tab filter)
- Branch merged up to date with main

### [x] Step: Migrate DailyPlan.tt to DB-driven coordinator
- ✅ Removed static `implementation-plan` tab (text phases 1-13 → now DB todos 502-516)
- ✅ Removed `completed-tasks` tab (static include)
- ✅ Removed stale "Phase 1.5 Complete" block from RESOURCES tab
- ✅ Added `📊 GANTT` tab (all sites) — JS Gantt chart from `planning_projects` stash, 12-month window, color-coded by status, grouped by site for CSC
- ✅ Updated RESOURCES tab Planning Quick Links to point to DB projects/todos
- ✅ Update Planning Quick Links: JS activateHashTarget() — hash links now auto-switch to correct tab (todo 508)
- ✅ Fixed Gantt tab | json TT filter → quoted strings (was breaking tab render)
- ✅ Updated Planning.tt YOU ARE HERE + Step 2 notes + Next Step callout
- ✅ Planning.tt text cleanup: collapse Phase 0 (done), add DB migration note with links for phases P0-P14
- ✅ Add sub-project collapsible accordion to Planning tab (todo 510) — requires server restart
- ✅ Add plan-project link form to Planning tab (todo 511) — AJAX link-existing form + POST /admin/plan/link_project route

**Session 8 (commit 3ebb9128, 346bcbe0):** Daily Schedule → own tab; priority_select.tt shared include; TT comment recursion fix; Zen Rule todo-workflow.md; time_of_day '' → NULL fix; Ollama todo 202 resolved.

**Session 9 (commit fb2d919f):** Planning tab drag-and-drop project reordering (native HTML5 D&D, admin only); POST /project/reorder endpoint saves sort_order to DB; sort_order column added to DBIC Result class; projects now ordered by sort_order first; ⓘ help tooltip added to Link existing plan form explaining plan vs project relationship. Server restart required for Project.pm changes.

**Session 10 (commit 157c28b4, merged 993f86a0):** Active priorities smart scoring — fetch 60 todos, Perl-side composite score (status tier + priority + stale penalty), excludes all done variants (numeric + string), in_progress beats new at same priority, shows top 25. Stale badge + orange border for todos >180 days. Quick-close button (admin) — AJAX POST /todo/quick_close marks done + creates log. Triage stale button (admin) — POST /todo/triage_stale bumps priority +2 for todos stale >180d. New blocking issue (project 192, todos 520-522) analyzed for scheduling impact; todo 520 (credentials file) confirmed blocker for API work.

### [x] Step: Refactor MasterPlanCoordination to coordinator-only role
- ✅ MASTER PLAN COORDINATION tab in DailyPlan.tt replaced: direct 1390-line INCLUDE → lean coordinator block
- ✅ Coordinator block: migration status banner, blocking dependency list (#11 Arch Phase 2, #4 Refactor, Unified Mail), 8-area DB quick links grid
- ✅ Legacy doc collapsed in `<details>` for CSC admin reference; standalone `/Documentation/MasterPlanCoordination` page unchanged
- ✅ commit eb5d3010

### [x] Step: Role-Based Access Documentation
- ✅ DailyPlanSystem.tt permission table updated — 7-row matrix with SiteName scope, DailyPlan access, text plan visibility, DB plan access
- ✅ Implementation note added: Root.pm UserSiteRole detection, /admin vs /user/profile paths, is_csc session flag gates CSC text tabs
- ✅ commit 5a7bd577

### [x] Step: DB Schema verification & migration
- ✅ All planning tables confirmed present: `dailyplan`, `dailyplan_project`, `daily_plan_entries`, `plan_audit`, `plan_benefits`, `plan_system_mapping`
- ✅ `allowed_roles` column NOT in `dailyplan` table — correct (no migration needed, controller uses session-based role detection)
- ✅ `sort_order` confirmed in `projects` table
- ✅ `DocumentationConfig.json`: 49 CSC-specific pages updated from `site:'all'` → `site:'CSC'` (dated DailyPlans archives, MasterPlan, PriorityTodos, DailyPlanSystem, etc.)
- ✅ commit ad6d1284

### [x] Step: Developer Time Logging & Points-Based Payment System [HANDOFF → dedicated branch pointsystem-XXXX]
<!-- chat-id: 9d8665e5-72c1-4d06-9953-e0ffe0cb7bd6 -->
**HANDOFF COMPLETE** — Dedicated Zenflow task created: `542abc9c` (Developer Time Logging & Points-Based Payment System, project f2638036).
- Existing infrastructure: `pointsystem-3230` branch merged to main; `Comserv::Util::PointSystem`, `PointLedger.pm`, `PointAccount.pm`, `PointPackage.pm` all in main.
- Related task: PointSystem `32301cc8` (in-review) covers customer-facing payment flow.
- Remaining work (developer time logging, point_rules, developer_points_ledger, payment_records tables, hooks, MY EARNINGS tab, admin payments view) handed to new task `542abc9c` to be executed on a new branch from main.

**Objective:** Integrate time tracking into the planning system so developers are compensated via a configurable points system redeemable as payments.

**DB tables needed (new):**
- `developer_time_log` — records every billable action: `id, user_id, site_name, action_type, entity_type (todo|plan|project), entity_id, minutes_spent, points_earned, notes, created_at`
- `point_rules` — configurable points per action per site: `id, site_name, action_type, points_value, is_active` (seeded with defaults)
- `developer_points_ledger` — running balance per user: `id, user_id, site_name, points_delta, reason, reference_id, reference_type, created_at`
- `payment_records` — payment disbursements: `id, user_id, site_name, points_redeemed, amount_paid, currency, payment_method, payment_date, status, approved_by, notes`

**Point-earning action types (seeded defaults):**
- `create_todo` — 5 pts
- `complete_todo` — 10 pts
- `create_plan` — 20 pts
- `create_project` — 15 pts
- `log_time` — points per hour (configurable, e.g. 60 pts/hr)
- `review_todo` — 3 pts
- `complete_plan` — 50 pts

**Integration points (hooks into existing system):**
- `Todo.pm::add_todo` — fire `log_point_event('create_todo', …)` after successful create
- `Todo.pm::modify` — fire `log_point_event('complete_todo', …)` when status → 'completed'
- `PlanManagement::create` — fire `log_point_event('create_plan', …)` after plan created
- `PlanManagement` — add `log_time` action: form on plan/todo detail page to log hours worked
- Utility: `Comserv::Util::PointsLedger` — `award_points($c, user_id, action_type, entity_type, entity_id, notes)` — looks up rule, writes ledger entry, returns points awarded

**UI additions to DailyPlan.tt:**
- New tab **MY EARNINGS** (all logged-in users): shows point balance, recent time logs, payment history
- Admin-only view in RESOURCES tab: total points owed per developer across all SiteNames, payment approval queue

**Payment flow:**
- Developer: requests payment via `/user/payment/request` → converts available points to payment request
- Admin: approves via `/admin/payments` → marks `payment_records.status = 'approved'`; sets amount based on points × rate (configurable per site)
- Integration note: actual money transfer is manual initially; system just tracks the record

**Branches/coordination:**
- `membership-1304` — coordinate for role definitions and user management
- This step should be handed to a dedicated branch: `pointsystem-XXXX`

**Implementation steps:**
- [ ] Create DB migration SQL for 4 new tables
- [ ] Add DBIC Result classes: `DeveloperTimeLog.pm`, `PointRules.pm`, `DeveloperPointsLedger.pm`, `PaymentRecord.pm`
- [ ] Create `Comserv::Util::PointsLedger` utility with `award_points` and `get_balance` methods
- [ ] Hook `award_points` into `Todo.pm` (create, complete) and `PlanManagement.pm` (create)
- [ ] Add `log_time` form to plan/todo detail pages
- [ ] Add MY EARNINGS tab to DailyPlan.tt
- [ ] Add admin payment approval view at `/admin/payments`
- [ ] Seed `point_rules` table with defaults per site

### [x] Step: Module Access Control System [HANDOFF → membership-1304]
<!-- chat-id: 609a241c-80e5-412b-83ec-b8eff105d48d -->
**Objective:** Allow admins to enable/disable named modules (planning, filemanager, apiary, ency, weather, etc.) per SiteName and optionally grant/revoke per user. This replaces the current hard-coded role checks with a DB-driven module registry.

**DB tables needed:**
- `site_modules` — per-site module toggle: `id, sitename, module_name, enabled, min_role, created_at` (UNIQUE: sitename+module_name)
- `user_module_access` — per-user override: `id, username, sitename, module_name, granted, granted_by, created_at`

**Initial seed data (via API):**
- All active SiteNames: planning=enabled, min_role=member
- Admin UI at `/admin/site_modules` to toggle modules per site, assign min_role
- User override UI at `/admin/users/{id}/modules` to grant/revoke

**Integration in Root.pm::auto:**
- Load `site_modules` for current SiteName into `$c->stash->{enabled_modules}` hashref
- Check `user_module_access` overrides for logged-in user
- Templates use `c.stash.enabled_modules.planning` to gate nav/content

**Navigation:**
- `TopDropListPlanning.tt` already uses `can_plan`; change to check `c.stash.enabled_modules.planning` once this step is done
- `navigation.tt` Apiary block: gate on `c.stash.enabled_modules.apiary` instead of SiteName hardcode

**Session 11 fix (commit 502c48de on main):**
- Planning menu `can_plan` now: any logged-in non-guest user (not role-gated) — content within DailyPlan is role/site filtered

### [ ] Step: Test & Verify
- Manual test: CSC admin sees text plan + DB plan
- Manual test: non-CSC user sees DailyPlan with DB-only tabs (no CSC text tabs)
- Manual test: all sites — Planning nav link goes to /Documentation/DailyPlan
- Manual test: plan creation form works (GET shows form, POST saves and redirects)
- Manual test: non-admin planning access via 'normal' role works (Planning nav now visible — commit 502c48de)
- Manual test: points awarded on todo create/complete (once points step implemented)
