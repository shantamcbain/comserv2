# Project Ownership, Sponsorship & Billing Plan

**Project code:** PROJ-OWN (proj #236)
**Parent project:** #138 PLANNING (this is a PHASE of the Planning System project)
**Site:** CSC
**Status:** In-Process — A1/A2/A3 decided; **Q4 and Q6 (steps) still block Ph3**
**Audit date:** 2026-08-02
**Standard:** follows [Planning Language Standard](/Documentation/PlanningLanguageStandard) — PHASE = sub-project, STEP = todo, GATE = done-when
**Coordinator:** [Comserv2 Master Plan](/Documentation/MASTER_PLAN) — Project #138 PLANNING
**Related phase:** PROJ-UI (235) todo 1847 — CSC SiteName filter
**Deliverable (one line):** separate who OWNS, who can SEE, and who PAYS for a project, so one site can sponsor another site's sub-project without handing over edit rights.

---

## 1. The problem

`sitename` currently means three things at once: who **owns** the work, who can **see**
it, and implicitly who **pays** for it. That collapses as soon as one site sponsors work
on another site's project.

The scenario, in the user's words: *site A owns a feature; site B wants something added
and is willing to pay for it.* Today there is nowhere to record that B funded it, and no
way to let A see B's sub-project without also being able to change it.

Intended rule: **A can see B's sponsored sub-project but not modify it. Only B or CSC
can.**

---

## 2. What exists now (verified 2026-08-02)

### `projects` — `Result/Project.pm`
`sitename` varchar(255) — the owner, and the only site concept
`client_name` varchar(255) — **free text, not a FK to sites**, used ad hoc
`username_of_poster`, `group_of_poster`
**No billing fields at all.**

### `todo` — `Result/Todo.pm`
`sitename`, plus three billing-ish columns with no project-level analogue:
`company_code` varchar(30), `billable` tinyint default 1, `share` int.
**Their actual usage is unaudited** — `share` in particular hints that split billing was
once intended. Audit before designing on top of them.

### Accidental half-support
Sub-projects are fetched by `parent_id` with **no sitename filter** (deliberate, per the
comment at `Project.pm:481`). A cross-site sub-project therefore already renders under a
foreign parent. The data model half-supports the scenario by accident — with no
authority model behind it.

---

## 3. Finding: `update_project` has no authorisation at all

`Project.pm:858 update_project` calls `_require_login($c)` — which checks only that
`session->{username}` exists and isn't `anonymous` (`Project.pm:13-21`) — and then
performs **no further check** before writing the full field set, **including
`sitename`** (~`:919`).

So today: **any authenticated user on any site can edit any project**, including
silently reassigning it to another site. `create_project` (`:92`) and the delete/reorder
paths need the same review. By contrast `Controller/Todo.pm:275` at least gates on
`admin|developer`.

This is exploitable now and is split out as **Ph1**, ahead of and independent of the
ownership design.

Precedent to avoid: `Accounting.pm`'s gate accepts `admin|site_admin|accounting` but is
**not SiteName-scoped** — it never checks the user administers the site in session.
Don't repeat that; scope to the specific project's site.

---

## 3.1 Finding (2026-08-18): the rollup assumed in A1 is **incomplete and partly wrong**

A1 states *"Hours already roll up… the only missing piece is who pays for them."*
Tracing the live code shows the rollup is **not** trustworthy today — and since these
hours become the basis for **billing owners and paying developers**, that matters before
any sponsorship table is built:

- `done_with_log` (`Controller/Todo.pm` ~3699-3702) closes a todo and writes a completed
  `log` row **without** adding elapsed time to `todo.accumulative_time`. Only
  `close_log`, `next_step`, and `Log.pm::create_log` bump the column. So hours logged via
  "mark done with notes" are **invisible to the stored total** — the cached column
  (`accumulative_time`) and the true sum (`log` WHERE status=3) disagree.
- `root/todo/project.tt` sums `todo.accumulated_time`, but the real column is
  `accumulative_time` (Result/Todo.pm). Every per-project "Xh" total computes against an
  **undefined accessor → 0**. The project-level rollup that billing would read is silently zero.
- `projectdetails_enhanced*.tt` references `todo.formatted_accumulated_time`, which is
  defined nowhere → no time shown / error.
- `log` carries `start_time`/`end_time` as TIME **only (no end_date)**; a session left
  open across midnight is clamped to 1 minute by `close_log`. Cross-day billing is wrong.

**Consequence for Ph3 / billing:** do **not** treat `accumulative_time` as the billing
number. Make `log` (status=3 rows) the single source of truth and recompute the rolled-up
column from `Log.pm::calculate_accumulative_time` on *every* close/done; fix the
`accumulated_time`→`accumulative_time` mismatch and the dead accessor; add `end_date` to
the close path; and add tests around the accumulator. Until then, any sponsorship/billing
rollup built on the current column would under-bill. Cross-reference:
`DAILY_PLAN_LAYOUT_REDESIGN.md` §"Time Tracking — evaluation + constraints".

---

## 4. How the industry solves this

Nobody sponsors a project *directly*. Every mature system inserts a **funding source**
entity between the work and the payer:

| Model | Shape |
|---|---|
| Jira/Tempo, Harvest, FreshBooks, Everhour | time entry → task → project → **billing account**; the account is a first-class row, and one project can bill to several |
| Kantata, Projectworks (prof. services) | a project carries one or more **funding sources / SOWs**, each with a payer, budget cap and date range; hours attribute to the SOW |
| Open Collective, Polar, Tidelift (bounty) | **many sponsors fund one issue**; each pledge is its own row with payer and amount |

**The lesson: never put the payer on the work row.** Payer is a *relation*, because the
moment two parties fund one thing a single `sponsor_sitename` column dies. This matches
the user's own instinct that "sponsorship could in theory be on all".

---

## 5. Decisions (2026-08-02)

### A1 — granularity
Billing today is **time in `log` → todo → project**, and that chain already works:
`Result/Log.pm` carries `todo_record_id`, `start_time`, `end_time`, `time`, `sitename`,
`project_code`, `points_processed`, with `belongs_to todo`; `Todo.pm:487-496` sums log
time into `accumulative_time`. **Hours already roll up. The only missing piece is who
pays for them.**

Decision: sponsorship is a **separate table, not a column**. One row = one sponsor
funding one target, with a **polymorphic target** so it can attach at any level later
without a schema change.

```
project_sponsorship {
  id, target_type ENUM(project, todo), target_id,
  sponsor_sitename, sponsor_user_id NULL,
  share_percent, budget_cap NULL,
  purpose TEXT,              -- funder's stated outcome, in THEIR terms (see grant analogy)
  funder_reference NULL,     -- grant number / PO / agreement id
  start_date, end_date NULL, status,
  created_by, created_at
}
```

`sponsor_user_id` NULL = the *site* sponsors; set it when an individual user does. That
single nullable column is what makes "any user(s) could sponsor" work without a second
design later.

### A2 — what the sponsor pays for
**Sub-project** in phase one, per the user. Because the target is polymorphic and
`share_percent` exists from day one, todo-level and split funding need **no schema
change** later — only UI. Do not hardcode a 1:1 assumption: **query sponsorships as a
list** even while the UI shows one.

### A3 — who owns the result
**A keeps ownership. `owner_sitename` never changes on delivery.** B's stake is a
financial claim, not ownership, so it lives on the sponsorship row (`share_percent` plus
a valuation note).

⚠ **Flag:** "a % based on the value the addition added" is a **revenue share / royalty**,
which is a different thing from cost recovery and is where this could balloon.
Recommendation: phase one **records the % and its basis as data only, with no automatic
calculation**. How "value added" is measured is a business rule, not a coding task, and
must not block the rest of this work.

### A4 — visibility: **yes, full read — and it is an oversight requirement**

The owner site owns the project, so it must be able to monitor what happens inside a
sponsored sub-project — that it is not building backdoors or connecting to questionable
sources. There are practical, ethical and **legal** implications: who is responsible for
the actions of the project.

**This reverses the industry default.** Elsewhere the payer sees detail and the host sees
aggregate. Here the **host sees everything, because the host carries the liability.**

- Owner A gets **full read** on B's sponsored sub-project — todos, descriptions, hours,
  logs, linked resources — not just the header. Read-only stays read-only: A still
  cannot edit (that remains B or CSC, per Ph1).
- Visibility is therefore **asymmetric by design**. Write that down, or a later developer
  will "fix" it into symmetry and delete the oversight.
- Because A sees B's hours, **hours are not confidential between sites** in this system.
  If a sponsor ever needs commercial confidentiality, that is a *new* requirement in
  direct conflict with oversight — flag it, don't silently pick a side.
- Ph3 should at minimum not make it harder for A to review what changed in a sponsored
  sub-project.

### The grant analogy — this changes the data model

> A seniors complex provides meals; the grant source funds **socialization**, not food
> availability or quality. They are funding **a seat in the dining hall**, not food on
> the table.

The sponsor's **purpose is not the work's purpose**. The funder is accountable to their
own outcome, not to the deliverable. So a sponsorship row needs a **purpose / intent**
field — what the funder is buying, *in their terms* — distinct from the sub-project's own
description. Reporting must answer "what did this grant achieve" in the **funder's**
terms, which may not map 1:1 onto todos completed.

Add to the table: `purpose TEXT` (funder's stated outcome) and `funder_reference varchar`
(grant number / PO / agreement id). Without these, grant-style sponsorship cannot be
reported on and **the money cannot be acquitted**.

### A6 — `client_name`: **retire**

Superseded by the sponsorship table. Audit current values, migrate anything meaningful
into a sponsorship row or comments, then remove from `Result/Project.pm` and the forms.
Do not leave a third overlapping concept beside owner and sponsor.

---

## 6. Dead fields — audited 2026-08-02

`todo.billable` (tinyint default 1), `todo.share` (int), `todo.company_code`
(varchar 30): a grep across `lib/Comserv/Controller/` finds **no business logic reading
any of them** — only `Admin.pm:3138` and `Api.pm:451` writing `share => 0` as a literal
default. They are vestigial.

**Do not build the sponsorship model on top of them.** Decide in Ph3 whether to repurpose
or drop them; leaving three dead billing-ish columns beside a real sponsorship table will
mislead the next reader.

---

## 7. Still open

| # | Question | Note |
|---|---|---|
| Q5 | Record ownership transfers as history? | Recommended **yes** — with legal responsibility now in scope (A4), an ownership audit trail is close to mandatory. Low urgency, does not block Ph3 |

**Answered:** Q1 (separate polymorphic table), Q2 (sub-project first, extensible),
Q3 (A keeps ownership; B holds a financial claim), Q4 (**full read for the owner — an
oversight/liability requirement, asymmetric by design**), Q6 (**retire `client_name`**).

**Constraint:** any new column or table goes into the Result class first and is applied
via `/schema-comparison/sync_result_to_table`. Never hand-write DDL. **Check whether it
already exists first** — `projects.priority` was already present while a stale code
comment claimed otherwise.

---

## 8. Phases

| Todo | Phase | Blocked by | Notes |
|---|---|---|---|
| 1848 | Ph1 — **security**: authorise `update_project` | — | urgent, independent of the design |
| 1849 | Ph2 — **design**: answer Q1-Q6, audit `company_code`/`billable`/`share` | — | no code until answered |
| 1850 | Ph3 — implement visibility, write authority, billing rollup | 1849 | |

Ph1 minimum fix: require CSC admin **or** site_admin of the project's current sitename;
treat a `sitename` **change** as strictly CSC-admin (it is an ownership transfer, and per
Q5 should be recorded, not silently applied).

Ph3 must be coordinated with PROJ-UI todo **1847** (CSC SiteName filter) — the open
"does a cross-site sub-project appear when filtering by site?" question there is
answered by this model, not independently.

---

## 7. Key file reference

| Path | Role |
|---|---|
| `lib/Comserv/Controller/Project.pm` | `_require_login` :13, `create_project` :92, `project()` :266, `fetch_projects_with_subprojects` :452 (sub-project no-sitename note :481), `build_project_tree` :710, `update_project` :858 |
| `lib/Comserv/Model/Schema/Ency/Result/Project.pm` | `client_name` :44, `sitename` :48 |
| `lib/Comserv/Model/Schema/Ency/Result/Todo.pm` | `company_code` :58, `share` :97, `billable` :175 |
| `lib/Comserv/Controller/Accounting.pm` | precedent to avoid — role gate not SiteName-scoped |
