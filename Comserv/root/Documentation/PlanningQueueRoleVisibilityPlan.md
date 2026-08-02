# Planning Queue Role Visibility Plan

**Project code:** PLAN-QUEUE
**Parent project:** 138 PLANNING (Planning System)
**Site:** CSC
**Status:** In-Process
**Audit date:** 2026-08-02
**Tracking:** every phase below has a todo under project PLAN-QUEUE. The todo carries the
gate condition. Do not work a phase whose gate is unmet.

---

## 1. Purpose

Audit finding: the planning "Focus Queue" decides what needs to be done using a server-side
score, but **role-based visibility is enforced only in client-side JavaScript, and it fails
open**. A member sees software-development todos. This plan closes that, makes the role
category real data instead of a regex guess, and reconciles the two inconsistent access
gates on `/planning` vs `/todo`.

---

## 2. Current behaviour (as-built, verified 2026-08-02)

### 2.1 Two surfaces, two different gates

| Surface | File | Gate |
|---|---|---|
| `/planning/daily` | `lib/Comserv/Controller/Planning.pm:35` | any authenticated non-guest: `admin\|developer\|devops\|editor\|user\|normal` (`:52-61`) |
| `/todo` | `lib/Comserv/Controller/Todo.pm:293` | `admin` or `developer` only; everyone else redirected to `/` (`:275`) |
| `/todo/update_*` AJAX | `Todo.pm:246` | session only — exempt from the admin gate |

### 2.2 Focus Queue candidate set — `Planning.pm:490-549`

```
status NOT IN (3,4,DONE,Completed,completed,Closed,closed,Done)
sitename = current site        (non-CSC forced; CSC honours session cal_filter_site)
user_id  = me                  UNLESS can_see_all
order priority ASC, is_blocking DESC, last_mod_date DESC, rows 2000
```

`can_see_all` (`Planning.pm:495`) = `is_admin` OR role in `developer|devops|editor`.
This is the **only** real role-based data scoping, and it scopes by *owner*, not by
work category.

### 2.3 Rejected in Perl — `Planning.pm:561-565`

- audit-panel todos (`ProjectDependencies::is_audit_panel_todo`)
- `todo_type` in `appointment|meeting|event|reminder`
- `is_recurring`

### 2.4 Scoring — `Planning.pm:603` (lower `ap_score` = higher in queue)

```
ap_score = status_tier*100
         + (priority + block_bonus + cross_block_bonus + due_bonus)
         + stale_penalty
```

| Term | Value | Effect |
|---|---|---|
| `status_tier` | 0 if status 2/5/"in progress", else 1 | in-progress work always outranks non-started |
| `block_bonus` | -0.4 if `is_blocking` | mild lift |
| `cross_block_bonus` | -1000 if it blocks another project (active `ProjectDependency` type `blocks`) | floats to absolute top |
| `due_bonus` | -5 overdue / -3 due today / -1 due <=3 days | |
| `stale_penalty` | +500 if >180d untouched, +50 if >90d | **buries** stale work |

### 2.5 Truncation

`FOCUS_QUEUE_LIMIT = 20` (`lib/Comserv/Util/ProjectDependencies.pm:6`).
Overflow renders as `+N more in backlog ->` linking to `/todo`
(`root/admin/planning/_today_work_tab.tt:124`) — a page members cannot open.

### 2.6 Default view

`root/admin/planning/DailyPlan.tt:99` — **TODAY'S WORK** tab is `active` on load for
everyone; content is the Focus Queue in `ap_score` order.
Tabs: today-work, daily-schedule, weekly-view, month-view, planning, gantt-view,
resources-view, and **project-planning which is CSC-only** (`DailyPlan.tt:120`).
Schedule/week/month are lazy-loaded by date.

### 2.7 Role classification and the filter UI

- `Planning.pm:1144 _classify_todo_roles()` keyword-matches
  `project_name + project_code + subject` into `developer` / `editor` / `admin`,
  defaulting to `general`. Emitted as `data-role-cats`
  (`_today_work_tab.tt:249`).
- Role dropdown renders **only** `IF ap_user_roles.size > 1`
  (`_today_work_tab.tt:134`); the checkboxes are the viewer's own roles, all
  pre-checked.
- Filtering is client-side: `root/static/js/planning/daily-plan.js:144 applyAllFilters()`.
- Site choice persists to session via `POST /planning/set_filter` (`Planning.pm:1035`).

**The defect** — `daily-plan.js:158-163`:

```js
var cardRoles = (card.dataset.roleCats || 'general').split(',');
var showRole = cardRoles.some(function(cr) {
    if (cr === 'general') return true;
    if (!allRoleVals.has(cr)) return true;   // <-- fails open
    return checkedRoles.has(cr);
});
```

A card whose category is not among the viewer's own roles is shown
**unconditionally**. Combined with 2.7's `size > 1` guard, a single-role member gets
no dropdown at all and every developer todo is rendered into their HTML. Role
classification currently controls nothing for non-developers, and because the server
never filters on `role_cats`, the data is in the page source regardless of CSS state.

### 2.8 CSC admin

`is_csc = uc(SiteName) eq 'CSC'` (`Planning.pm:42`). CSC gets all sites in the
calendar/site lists (`:141-147`, `:666-702`), cross-site projects and plans, no
`sitename` clause on the audit / helpdesk / scheduled panels, the extra
project-planning tab, and the site multi-select.
On `/todo` the site dropdown is gated on role `admin` alone (`Todo.pm:429`) — **not**
on CSC — so a non-CSC site admin also gets an all-sites dropdown there.

---

## 3. Findings

| ID | Severity | Finding |
|---|---|---|
| F1 | High | Role filtering is client-side and fails open — members see developer work |
| F2 | High | `role_cats` is regex keyword guessing over free text, not stored data |
| F3 | Med | Access model inconsistent: `/planning` permissive, `/todo` admin-only, `/todo` site dropdown gated on `admin` rather than CSC |
| F4 | Med | "+N more in backlog" link sends non-dev users to a page they are redirected out of |
| F5 | Med | `stale_penalty` +500 permanently hides >180d items from the top 20 — work ages out of visibility silently |
| F6 | Low | Top-20 cap has no per-role or per-project quota; one cross-blocking project (-1000) can occupy the whole queue |

---

## 4. Execution phases

Each phase = one todo under project PLAN-QUEUE. Gate must pass before the next starts.

### Phase 1 — Server-side role scoping (F1)
Add a `role_cats` filter to the Focus Queue query path in `Planning.pm`, derived from
the viewer's roles. Remove the `!allRoleVals.has(cr)` escape hatch in
`daily-plan.js:161` so the client filter matches the server. A viewer with no matching
role category sees `general` + their own categories only; `admin`/CSC unchanged.
**Gate:** logged in as a plain `user`/`normal` member, view source of
`/planning/daily` — zero cards carrying `data-role-cats` containing `developer`.

### Phase 2 — Backfill and consume `todo.role_category` (F2)

**Verified 2026-08-02 against `ency`: the column EXISTS** as `varchar(64) NULL default
NULL`, synced via schema-compare. **The schema step is complete — no further DDL.**

| Item | Value |
|---|---|
| Database | `ency` |
| Table | `todo` |
| Column | `role_category` — `varchar(64)` NULL |
| Meaning | comma-separated set from `developer,editor,admin,general`; NULL read as `general` |
| Result file | `lib/Comserv/Model/Schema/Ency/Result/Todo.pm` |

Remaining work — populate and consume it:

1. **Backfill** — run `_classify_todo_roles()` (`Planning.pm:1144`) once over all open
   todos and write into the column. Snapshot `record_id` + current value to a TSV under
   `Comserv/logs/` **before** the first UPDATE.
2. **Read it** — change `Planning.pm:630` to use `$h{role_category}` (fallback
   `general` when NULL) instead of running the regex on every row of every render.
3. **Write paths** — add `role_category` to the `@allowed` list in the todo-update
   endpoint (`Api.pm:1134-1141`, where it is currently **missing** — an API write of
   that field is silently ignored) and to `/api/todo/create`, plus a classified default
   in the todo-create controller action so new rows arrive already classified.
   Contrast with `projects.priority`, which *is* present at `Api.pm:1233` and works.
4. **Demote the regex** to seeder-only: backfill script and create-default, never the
   render loop.

**Gate:** every open todo has a non-NULL `role_category`, `Planning.pm` no longer calls
`_classify_todo_roles` inside the Focus Queue loop, a newly created todo comes out
already classified, and an API write of `role_category` is honoured.

### Phase 3 — Reconcile access gates (F3, F4)
Align `/todo`'s `begin` gate with `/planning`'s: allow authenticated non-guests, scoped
to their own todos + role categories. Re-gate the `/todo` site dropdown on
`is_csc && admin` rather than `admin` alone. Make the backlog link point somewhere the
viewer can actually open.
**Gate:** member reaches `/todo`, sees only their own permitted todos, no site
dropdown; backlog link resolves 200 for that member.

### Phase 4 — Queue fairness and stale surfacing (F5, F6)
Replace the +500 stale bury with a visible "needs triage" bucket rendered outside the
top 20. Add a per-project cap so a single cross-blocking project cannot fill the queue.
**Gate:** a >180d todo is visible somewhere on the page without opening `/todo`, and no
single `project_id` occupies more than half the Focus Queue.

### Phase 5 — Verification
Manual pass as four personas: member, editor, developer, CSC admin. Record which cards
each sees in section 5 below.
Sub-project **187 PLAN-P2 "Phase 2: Role & SiteName Access Control"** was marked
*Completed* but was **reopened to In-Process on 2026-08-02** by this audit — the role
dimension was never enforced server-side. Re-close 187 only once the persona matrix
confirms role **and** site access control both hold.
**Gate:** persona matrix recorded in section 5, and 187 either closed or its remaining
gap documented.

---

## 5. Persona verification matrix

_(filled in during Phase 5)_

| Persona | Roles | Sites visible | Role cats visible | Site dropdown | `/todo` access |
|---|---|---|---|---|---|
| Member | user | | | | |
| Editor | editor | | | | |
| Developer | developer | | | | |
| CSC Admin | admin @ CSC | | | | |

---

## 6. Key file reference

| Path | Role |
|---|---|
| `lib/Comserv/Controller/Planning.pm` | `/planning/daily`, Focus Queue build + scoring, `_classify_todo_roles`, `set_filter` |
| `lib/Comserv/Controller/Todo.pm` | `/todo` list, admin/developer gate, calendar views, todo APIs |
| `lib/Comserv/Util/ProjectDependencies.pm` | `FOCUS_QUEUE_LIMIT`, cross-project blocker logic, audit-panel detection |
| `root/admin/planning/DailyPlan.tt` | tab shell, default active tab, CSC-only tab |
| `root/admin/planning/_today_work_tab.tt` | Focus Queue cards, filter bar, `data-role-cats` |
| `root/static/js/planning/daily-plan.js` | `applyAllFilters()` — the failing-open role filter |
