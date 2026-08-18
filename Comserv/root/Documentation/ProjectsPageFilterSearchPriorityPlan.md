# Projects Page — Filter, Search & Priority Plan

**Project code:** PROJ-UI (proj #235)
**Parent project:** #138 PLANNING (this is a PHASE of the Planning System project)
**Site:** CSC
**Status:** In-Process
**Audit date:** 2026-08-02
**Standard:** follows [Planning Language Standard](/Documentation/PlanningLanguageStandard) — PHASE = sub-project, STEP = todo, GATE = done-when
**Coordinator:** [Comserv2 Master Plan](/Documentation/MASTER_PLAN) — Project #138 PLANNING
**Sibling phase:** PLAN-QUEUE (234) — `/Documentation/PlanningQueueRoleVisibilityPlan`
**Deliverable (one line):** make the Projects page's `priority` column real in the DB and wire filter + search + priority so they actually apply.

Page under audit: `/project/project` — `lib/Comserv/Controller/Project.pm:266`,
template `root/todo/project.tt`.

---

## 1. Findings

| ID | Severity | Finding |
|---|---|---|
| P1 | High | `projects.priority` declared in the Result class but **never created in the DB** |
| P2 | High | Project filter dropdown is a **no-op** — controller reads it, never applies it |
| P3 | High | `is_parent_of_filtered_project` MACRO returns a **string, always truthy** — defeats every template-side skip |
| P4 | High | Search **cannot see sub-projects** — `data-search` only emitted on top-level cards |
| P5 | Med | Search **cannot navigate** — no name attribute, no link to details, Enter loses the term |
| P6 | Med | Priority dropdown hardcodes **High/Medium/Low = 1/2/3**, contradicting the 1-10 `Util::Priority` scale |
| P7 | Low | `role_filter` read and stashed with **no UI control and no consumer** |
| P8 | Low | Inline `<script>` in `project.tt:700` — banned in templates using `js_load.tt` |
| P9 | Med | Project details shows the **raw `parent_id` number** instead of the parent's name |
| P10 | High | `priority` is absent from **every project form, both save paths, and the details view** |
| P11 | Med | CSC admin sees **all sites with no way to narrow** — no SiteName filter on the projects view |

---

## 2. Detail

### P1 — `projects.priority` exists, but nothing reads or writes it

**Verified 2026-08-02 directly against `ency`:** the column is already present as
`int(11) NULL default 5`. **No schema change is required.**

The NOTE at `Result/Project.pm:75-81` ("until the column exists in `projects`, DBIC will
emit `SELECT me.priority` and the project list will fail") is **stale** — it describes a
condition that has since been resolved and misleads readers into thinking a sync is
pending. Delete it.

What is actually broken is the app-side read path, which clobbers the stored value.
(The API is fine — `Api.pm:1233` already lists `priority` in `@allowed`, and a
write/read round-trip was confirmed working on 2026-08-02.)

- `Project.pm:541` hardcodes `priority => 2` inside `fetch_projects_with_subprojects`,
  discarding the real column value on every list render.
- `Project.pm:607` `enhance_project_data` forces `priority ||= 2`.
- `Project.pm:304` stashes a `success_message` announcing that fudge as a feature.
- `project.tt:165-169` hardcodes High/Medium/Low = 1/2/3 against the 1-10
  `Util::Priority` scale.

### P2/P3 — the project filter does nothing

`Project.pm:266-318` reads `role`, `project_id`, `priority` from the query string
(lines 274-276), logs them (279), stashes them (298-300) — and **never filters
`$projects`**. The whole tree reaches the template.

The template tries to compensate: `project.tt:180` and `:183` skip non-matching
projects, mirrored at `:454`/`:457` inside the `display_subprojects` macro. Two things
defeat that:

- **Priority** (`:183`) compares against `project.priority`, which `enhance_project_data`
  has forced to `2` for everything. Choosing High or Low hides all; Medium hides none.
- **`is_parent_of_filtered_project`** (`:670`) is a TT `MACRO ... BLOCK`. A BLOCK macro
  returns its **rendered text**, not a value — here whitespace plus `0` or `1`. A
  non-empty string is always truthy, so the "keep ancestors visible" escape clause at
  `:180`/`:454` matches every project and nothing is ever skipped.

Fix direction: filter server-side in the controller / `fetch_projects_with_subprojects`
rather than via template `NEXT IF`; fix or retire the macro.

### P4/P5 — search

`project.tt:150` renders the input; `:721 filterProjects()` matches `data-search`.
`data-search` is emitted **only** on the top-level card (`:186-187`). The sub-project
card at `:459` has none, so the `.collapsible-card[data-search]` selector at `:723`
never sees sub-projects — searching a sub-project name gives "Showing 0 of N".

The input also has **no `name` attribute**, so pressing Enter submits
`projectFilterForm` without the term; the page reloads and the search is lost. And a
match only toggles `style.display` — there is no link from a result to
`/project/details?project_id=<id>`.

### P6 — priority scale conflict

`project.tt:165-169` hardcodes three options. `lib/Comserv/Util/Priority.pm` is the
single source of truth for the 1-10 scale (default 5) and already feeds every other
dropdown through the `build_priority` stash key and `root/todo/priority_select.tt`.
Use that partial; do not author a second scale.

### P9 — details page shows the raw parent_id

`root/todo/projectdetails.tt:39` prints the foreign key directly:

```
<tr><td><strong>Parent Project ID</strong></td><td>[% project.parent_id OR '—' %]</td></tr>
```

The stash comes from `build_project_tree` (`Project.pm:710`), whose `$project_hash`
(lines 726-745) copies `parent_id` but never resolves a `parent_name` — the template has
nothing else to print. `Result/Project.pm:91` already defines the `belongs_to parent`
relation, so the lookup is available.

Fix: add `parent_name` in `build_project_tree` (guarded — `parent_id` may be NULL, 0, or
point at a deleted row), render it as a link to
`/project/details?project_id=<parent_id>`, and relabel the row to "Parent Project".
Check `projectdetails_enhanced.tt` and `projectdetails_enhanced_enhanced.tt` for the same
pattern — fix the class, not the one line. Those two near-duplicates are themselves a
consolidation candidate.

### P10 — priority wired nowhere

Declaring the column is necessary but not sufficient. `priority` is missing from:

1. `root/todo/editproject.tt` — no control (status select is at :24-31)
2. `root/todo/add_project.tt` — no control
3. `Project.pm` `update_project` (~:915-930) — absent from the `$project->update({...})`
   hash, so a posted value would be silently dropped
4. `Project.pm` `create_project` (~:157-170) — absent on insert
5. `build_project_tree` (:726-745) — absent, so details cannot display it

Fudges to remove once the column is live: `Project.pm:541` hardcodes `priority => 2`
inside `fetch_projects_with_subprojects`, and `:607` forces `priority ||= 2`.

All controls must render from `Util::Priority` via `root/todo/priority_select.tt`.

### P11 — no SiteName filter for CSC admin

`fetch_projects_with_subprojects` already knows who is CSC: it computes `$is_csc_admin`
(`$is_admin && uc($SiteName) eq 'CSC'`) and then does

```perl
unless ($show_all || $is_csc_admin) { $search_cond{sitename} = $SiteName }
```

so CSC admin gets **every** site with no way to narrow, and everyone else is hard-pinned
to their own. `project.tt` has no site control at all — `sitename` appears only inside
the `data-search` string at `:185`. The `project()` action reads `role`, `project_id`
and `priority` from the query string, but no sitename.

**Reuse the planning pattern, don't invent one.** The Daily Plan already solves this:

- `_today_work_tab.tt:149-165` — multi-select site dropdown with an "All Sites" entry,
  rendered only when `ap_all_sitenames.size > 1`
- `Planning.pm:666-702` — builds the CSC site list from the `Site` resultset plus
  distinct sitenames actually present on rows
- `POST /planning/set_filter` (`Planning.pm:1035`) — persists the choice into session
  `cal_filter_site` so it survives navigation

Requirements: CSC-only (the control must not render for others); All / one / several;
**filter server-side** in the resultset, not with template `NEXT IF` — that is exactly
the failure already logged as P2/P3; persist in session; define precedence against the
existing `?all=1` toggle.

**Open decision:** sub-projects are currently fetched by `parent_id` with no sitename
filter (deliberate, per the comment at `Project.pm:481`). When filtering by site, does a
sub-project in site B under a parent in site A appear? Recommend showing it with a site
tag — the way the planning filter tags cross-site rows — otherwise the tree breaks.

---

## 3. Execution phases

Tracked as todos under project 235 PROJ-UI.

| Todo | Phase | Blocked by | Covers |
|---|---|---|---|
| 1830 | Ph1 — wire priority end-to-end, adopt the shared 1-10 scale | — | P1, P6 |
| 1831 | Ph2 — apply filters server-side, fix/retire the macro | 1830 | P2, P3, P7 |
| 1832 | Ph3 — search sub-projects, make results navigable, de-inline JS | 1830 | P4, P5, P8 |
| 1833 | Ph4 — end-to-end verification, both personas | 1832 | — |
| 1835 | Ph5 — show parent project name, not raw id | — | P9 |
| 1836 | Ph6 — wire priority into forms, save paths, details | 1830 | P10 |
| 1847 | Ph7 — CSC admin SiteName filter (All / selected) | 1831 | P11 |

**No phase is waiting on a schema sync.** Both `projects.priority` and
`todo.role_category` were verified present in `ency` on 2026-08-02.

---

## 4. Key file reference

| Path | Role |
|---|---|
| `lib/Comserv/Controller/Project.pm` | `project()` :266 filters, `enhance_project_data` :595, `fetch_projects_with_subprojects` :452 |
| `lib/Comserv/Model/Schema/Ency/Result/Project.pm` | `priority` declared :82, uncreated in DB |
| `lib/Comserv/Util/Priority.pm` | the 1-10 scale, single source of truth |
| `root/todo/project.tt` | filter panel :147, skips :180/:183, macro :670, inline JS :700, search :721 |
| `root/todo/priority_select.tt` | shared priority dropdown partial to reuse |
