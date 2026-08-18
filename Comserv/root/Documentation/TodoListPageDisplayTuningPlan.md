# Todo List Page Ranking & Display Tuning Plan

- **Project code:** TODOLIST-UI ([proj #240](/project/details?project_id=240))
- project_id = "240"
- project_code = "TODOLIST-UI"
- **Parent project:** #138 PLANNING (this is a PHASE of the Planning System project)
- **Standard:** follows [Planning Language Standard](/Documentation/PlanningLanguageStandard) — PHASE = sub-project, STEP = todo, GATE = done-when
- **Coordinator:** [Comserv2 Master Plan](/Documentation/MASTER_PLAN) — Project #138 PLANNING
- **Created:** 2026-08-05
- **Deliverable (one line):** Make the main Todo list page rank and display the way the daily triage does,
  so important items (PROJ-UI phase 1, PLAN-QUEUE phase 1, the ACC sign-off gates) float to the top instead of
  stale p1 noise (dead Ollama stubs, SUPERSEDED rows, routine daily-plan entries).

## Diagnosis (why the page currently diverges from triage)

The main Todo list (`Comserv/lib/Comserv/Controller/Todo.pm:408`) sorts with:

```
order_by => { -asc => ['priority', 'start_date'] }
```

Two defects:
1. **`priority` is broken by the p1-inflation bug** (TT `current_priority` defaulted to
   1), so ~818 todos are p1 and the field carries almost no signal.
2. **`start_date ASC` rewards stale work** — oldest rows float to the top *because they
   are old*, not because they matter.

Meanwhile the **Planning Focus Queue** (`Comserv/lib/Comserv/Controller/Planning.pm:538-659`)
already ranks correctly with `ap_score`: stale penalty (>90d +50, >180d +500), due-soon
boost, cross-blocker boost, and it excludes `is_recurring` and audit-panel rows. The two
views use **two different algorithms**, which is why the app list and the triage disagree.

## Phase 0 — Reparent Daily Plan ritual to this project
- Move the active "Daily Plan update" todo (rec 324) and its sibling testing/review rows
  (317, 322, 323, 325, 347) from project 1 to project 240.
- GATE: `GET /api/todos?project_id=240` shows them; `GET /api/todos?project_id=1` no
  longer does.

## Phase 1 — Extract the ranking scorer to a shared Util
- Move the `ap_score` scoring loop out of `Planning.pm` into
  `Comserv/lib/Comserv/Util/TodoRanking.pm` so both the Focus Queue and the main Todo
  list call the same function.
- Wire `Todo.pm` index to rank by that score instead of raw `priority, start_date`.
- GATE: the main Todo list top 20 matches the Focus Queue ordering for CSC admin.

## Phase 2 — Add demotions so noise sinks
- Subject matches `/SUPERSEDED/i` → large penalty (handles the "setup k8s -> SUPERSEDED"
  row).
- Project-1 routine daily-plan entries ("Daily time", "daily Plan update", the 484
  daily-plan stubs) are NOT `is_recurring`, so the current filter misses them — demote
  them below substantive work.
- GATE: SUPERSEDED rows and routine daily-plan entries do not appear in the top 50 of the
  main list.

## Phase 3 — Dead-row audit (REVISED: no deletion)
Original plan hypothesized a batch of "dead 2026-06-11 Ollama stubs" to close. A full read
(2026-08-05, live /api/todos) disproves it: 135 open todos are dated 2026-06-11 and they are
a broad, legitimate mix — UI bugs (todo priority display, calendar, edit-link errors),
the DOCSYS documentation series (294-314), the API-domain series (354-380), and Ollama
feature work. The 15 Ollama-cluster rows (rec 252/262-270/273/275-278) belong to real,
active projects 129/131/132 (parent 105, In-Process/Requested) and are correctly owned
there. Per Rule 15 (no silent cross-project re-parent) and Rule 6 (don't fabricate a
"dead" classification from a sample), Ph3 does NOT delete or re-parent them. The ranking
fix (Ph1/Ph2) already ensures they surface appropriately. **No rows were mutated for Ph3.**
GATE: 0 rows deleted/re-parented; plan narrative corrected instead.

## Phase 4b — Expose time-log open/close via the API (auto-log from agent)
- Added `POST /api/todo/open_log`, `/api/todo/close_log`, `/api/todo/done_with_log` to
  `Comserv/lib/Comserv/Controller/Api.pm`. These mirror `Todo.pm`'s `open_log`/`close_log`/
  `done_with_log` raw SQL exactly, but authorize via the same local-network bypass as
  `/api/todos` (localhost / 192.168.1.*) instead of a browser session. Now an agent or
  script can open a log when starting a todo and close it when finishing — the same
  bookkeeping the Start/Done buttons do, no session cookie needed.
- Verified live: open_log created log_id 644 + set todo 1920 -> status 5; close_log closed
  it (1 min) + reset to status 2. DB confirmed (last_mod_by=Shanta).
- NOTE: a test log row (record_id 644) was created on rec 1920 during verification; it is a
  connectivity test, not real work. Remove it before trusting rec 1920's time total
  (needs a direct `DELETE FROM log WHERE record_id=644`, gated on DB-cred consent).

## Phase 5 — Focus Queue sorting & filtering UX (the actual todo-list sort/filter work)
Scope: ONLY the Today's Focus Queue (`_today_work_tab.tt` + `daily-plan.js`/`daily-plan-utils.js`).
No other list, no new/modified planning todos.

Discovered 2026-08-05 from the live Focus Queue: the filter bar and sort buttons have real
gaps. Findings (verified by reading the code):

1. **No All/None toggle per filter.** Role and Project dropdowns render individual checkboxes
   (all checked by default) with NO master control — you must toggle each off one at a time.
   Only Site has a master (`site-all-cb`). `clearAllFilters` exists but only sets everything
   ON; there is no "select none".
   **OPEN FINE-TUNING (not yet done):** the filter model is still "everything checked by
   default" — the All/None buttons are a band-aid. The deeper two-part system the user wants
   is a proper tri-state (All / None / Custom) where "None" or a curated subset is a sensible
   default, not "All is always checked". This needs a design decision: what should the
   default selection be (None, or a role/site-scoped subset) rather than "show everything".
2. **No tooltips.** Sort buttons (Score/Priority/Project/Due) and filter dropdowns explain
   nothing on hover — user can't tell what each does. (DONE: tooltips added 2026-08-05.)
3. **Score vs Priority do nothing different (real bug).** `sortTodos('score')` orders by
   `data-score` (`ap_score`); `sortTodos('priority')` ordered by `data-priority` THEN
   `data-score`. Because ~800 rows are p1 (the p1-inflation bug), both collapsed to the same
   `data-score` tiebreak → identical order. (DONE: Priority now sorts by raw priority band →
   due date, ignoring the smart score, so it is genuinely distinct from Score.)
4. **Role/Site focus filter works** (`applyAllFilters` hides cards by `data-role-cats` /
   `data-site` / `data-project-id`) but the server scorer does not reorder by role — it is a
   client-only filter, which is correct for a view toggle.

### Deliverables (built 2026-08-05)
- **Endpoint:** `POST /api/focus/top5` in `Api.pm` (local-network bypass). Gathers the FULL
  scored CSC-open set (top 50 by `TodoRanking::score_todo`), sends them to the AI2 Ollama
  provider with a ranking prompt, parses 5 `record_id`s + a one-line rationale each.
- **INDEPENDENCE GUARANTEE (user requirement):** the AI selection is computed from the full
  scored set and is **NOT affected by the Focus Queue's Role/Site/Project filter toggles**.
  The button result is advisory only — it never reorders, closes, or mutates any todo, and is
  rendered as a distinct "🤖 AI Top 5" section above/separate from the filtered queue.
- **Model:** default curated local Ollama (`phi4:14b`), falls back to `AI2::Router` default
  (user decision: "list but fall back to the default"). Reuses `Model::AI2::Provider::Ollama`
  — no second AI path.
- **UI:** "🤖 AI: Top 5" button + render section in `_today_work_tab.tt`, wired in
  `daily-plan.js` (POST + render, with Thinking/error states). Clicking a pick opens the real
  todo; no mutation.
- Verified: `Api.pm` syntax OK; live endpoint returns HTTP 200 with clean `success:0` +
  `"AI ranking unavailable"` when Ollama is down (graceful, no crash). Full AI ranking needs
  the local Ollama model running.

### GATE (when built)
- "AI Top 5" returns 5 distinct, currently-open CSC todos with a rationale string each.
- Clicking a suggested item opens the real todo; no todo is mutated by the suggestion.
- Works via local Ollama by default (no external API cost) with cloud fallback.
- **The AI Top 5 does NOT change when the Role/Site/Project filters change.** (user requirement)
- A1. Add an **All / None** master toggle to the Role, Site, and Project dropdowns (DONE:
   master buttons added 2026-08-05; see OPEN FINE-TUNING above for the deeper default-state
   redesign).
- A2. Add **tooltip (`title`) attributes** to every sort button and filter summary. (DONE.)
- A3. **Make Score and Priority genuinely distinct.** (DONE: Priority = raw band → due.)
- A4. (Follow-on) Redesign the filter default-state to a real two-part/tri-state system
   (All / None / Custom) where "show everything" is NOT the forced default. **Key principle
   (user 2026-08-05): this logic must live in a shared `Comserv::Util::*` module, not inline
   in the Focus Queue template/controller, so any system that needs filtering/ranking reuses
   one implementation.** The All/None buttons already added are a stopgap; the durable fix is
   a Util that owns filter state + default selection, consumed by the Focus Queue, /todo, and
   future panels alike.

### GATE
- Each Focus Queue filter dropdown has an All + None control; toggling None hides every row
  of that dimension; All restores.
- Hovering any sort button / filter shows a tooltip explaining the action.
- Clicking Priority vs Score produces two observably different orderings.

## Phase 5b — AI-evaluated "Top 5" for the Focus Queue (proposed 2026-08-05)
The mechanical score (Ph1/Ph2) and filters (Phase 5) still don't *reason* about what is
most worth doing now. Proposal: let an appropriate AI pick the 5 todos to work on next,
reusing the existing AI backend (`Model::AI2::*` providers + `AI2::Router`; also `/api/chat`
in `AI.pm` and `/ai2/chat`). Render that as a distinct "AI Top 5" section above the queue.

### Design (needs user decisions — do NOT build until answered)
- **Where the call runs:** server-side controller action (e.g. `Planning.pm` or a new
  `Api.pm` `/api/focus/top5`) that gathers the scored CSC-open todos, sends them to the AI2
  provider with a ranking prompt, and returns 5 record_ids + a one-line rationale each.
  Keeps the AI logic out of JS and reusable by the Chat-with-AI panel too.
- **Which model:** default to a curated local Ollama model (no API cost); if unavailable,
  fall back to the system default model used by the chat panel. (User decision 2026-08-05:
  "list but fall back to the default".)
- **Trigger:** manual "AI: pick my Top 5" button (not auto on load) so it is deliberate and
  cacheable; store the result + timestamp and let the user refresh.
- **Input shape:** top N (e.g. 50) scored todos with subject/priority/due/blocker/project,
  so the AI reasons over a manageable set, not all 742.
- **Guardrails:** AI output is advisory only — it cannot reorder/close todos, just suggests.
  The suggested 5 link to the real todos. Never auto-mutate from the suggestion.
- **Reuse Chat-with-AI:** the same prompt/action should be invokable from the AI chat panel
  ("rank my focus queue") so we don't build two paths.
- **Shared-Util principle (user 2026-08-05):** the AI ranking, the filter state, and the
  All/None tri-state all belong in `Comserv::Util::*` (e.g. a `Util::FocusRanking` or extended
  `TodoRanking`), NOT inline in the Focus Queue. Any system needing todo ranking/filtering
  reuses one implementation.

### GATE (when built)
- "AI Top 5" returns 5 distinct, currently-open CSC todos with a rationale string each.
- Clicking a suggested item opens the real todo; no todo is mutated by the suggestion.
- Works via local Ollama by default (no external API cost) with cloud fallback.

### BUILT (2026-08-06) — restores the lost "pick the top todo from both the .tt and the todo system" behavior

`api_focus_top5` in `Comserv/lib/Comserv/Controller/Api.pm` (`POST /api/focus/top5`) now
gathers **both** planning sources and feeds them to the AI combined:

1. **Todo system** — the full scored CSC-open set (top 50 by `TodoRanking::score_todo`),
   as before.
2. **Plan docs — BOTH:**
   - **On-disk corpus** — `root/Documentation/**/*.{tt,md}` whose names look like plan
     docs (plan/roadmap/phase/strategy/design/proposal/todo). Each is stripped of TT/HTML
     cruft and excerpted (4 KB cap, 60-file cap) so the AI sees the plan's prose; bullet
     lines that read as pending work are pulled out as `next_steps`.
   - **DB `DailyPlan` rows** — active (non-completed) plans, each with its open phase todos
     (`Todo` rows where `plan_id` = the plan) so the AI can pick an existing todo OR cite a
     doc-only step.

The AI returns up to 5 picks. A pick is **either** a real todo (`type:"todo"`,
`record_id` from the scored set — linkable, never mutated) **or** a plan-doc-only next
step (`type:"plan_item"`, with `title`/`step`/`plan_id`/`path` — advisory text only, no
todo is created or changed). All guardrails hold: advisory only, independent of the Focus
Queue filter toggles, reuses `Model::AI2::Provider::Ollama` (local Ollama default,
`AI2::Router` fallback), graceful `success:0 "AI ranking unavailable"` when Ollama is down.

NOTE: Phase 5b / 5b-built is now implemented (not scope-only). The front-end "🤖 AI: Top 5"
button + render section in `_today_work_tab.tt` (wired in `daily-plan.js`) is still the
outstanding UI half — without it the endpoint is callable directly but not surfaced on the
Focus Queue page.

### REDESIGNED (2026-08-06) — AI selection is the TUNING SIGNAL, not just a display

Goal reframed by the user: this feature exists to help **tune the project/todo ordering**
for fast, accurate development of the app + the plans their users manage — NOT just to show
an advisory list. The earlier `triage_stale` (wrote to the broken `priority` column) and
`_do_reschedule` (rewrote `start_date`/`time_of_day` for every todo) both attacked the
columns that were already meaningless/broken, so they created more problems than they
solved. The fix is to tune the **sorting signal** (the `TodoRanking::score_todo` weights),
non-destructively, and let a human *compare* before applying anything.

What changed:

1. **`TodoRanking::score_todo` is now weight-injectable.** A new optional `weights` key in
   the `%ctx` hash overrides any of the scoring constants (keys: `stale_90`, `stale_180`,
   `block`, `cross_block`, `due_overdue`, `due_today`, `due_soon`, `superseded`, `routine`,
   `status_tier`). When the key is absent the package constant is used — so every existing
   caller (Focus Queue, `/todo` list, calendar) gets **byte-identical output**. The override
   is read-only: it never mutates the constants or any stored column. Verified by unit test
   (`/tmp/test_todo_ranking_weights.pl`): originals untouched, default constants intact,
   partial override falls back to the constant.

2. **`api_focus_top5` now returns a tuning PREVIEW instead of just picks.** The AI is asked
   for a structured object:
   - `picks` — up to 5 top things to work on next (todo pick or plan-doc-only step).
   - `proposed_order` — the full record_id ordering it prefers (vs the coded score).
   - `weights` + `weights_why` — proposed RETUNING of the scorer weights (numeric, coerced;
     never trusted blindly; garbage values dropped).
   - `comparison.coded_top20` vs `comparison.simulated_top20` — the current code-ordered
     top 20 next to the **simulated** top 20 recomputed with the AI's proposed weights. The
     simulation re-scores a COPY of the candidates; **nothing is written** to any todo or plan.
   - `mis_set_todos` — todos the AI flags as wrong/mis-set (wrong priority, missing project,
     should-be-done, routine-mislabelled) — the known backlog of mis-set todos. Flagged only.

   The human reviews `coded_top20` vs `simulated_top20` + `mis_set_todos`. If the
   AI-ordered result is genuinely better, that insight feeds (a) the overall sort (the
   proposed `weights` are applied by re-scoring, not by editing rows) and/or (b) correcting
   each mis-set todo's settings individually — the cleanup the backlog needs, done
   deliberately rather than by a blunt bulk mutation.

GUARANTEE: at no point does this endpoint or the scorer write to `priority`, `start_date`,
`status`, or any other todo/plan column. It is read + compute + return. Applying a tuning
stays a separate, reviewed step driven by the preview.

### UI SHIPPED (2026-08-06) — "🤖 AI: Tune" button on the Focus Queue shows the difference

The Focus Queue (`_today_work_tab.tt`) now has an **AI Focus-Tune bar** (admin only):
a **🤖 AI: Tune** button, a **model `<select>`**, and a **⚖ Compare Models** button.
Wired in `daily-plan-utils.js` (button IDs `ai-tune-btn` / `ai-tune-model` /
`ai-tune-compare` / `ai-tune-status` / `ai-tune-result`), styled in `daily-plan.css`.

- The model dropdown is populated on load from a new `GET /api/focus/models`
  endpoint (lists installed Ollama + external models; falls back to `phi4:14b` if
  none are running). The operator picks the model; `api_focus/top5` then uses that
  model EXACTLY — **no silent swap to a "better" model**, so comparisons are honest.
- **🤖 AI: Tune** calls `/api/focus/top5?model=…` and renders, in the result panel:
  - the **top picks** (linkable todos + plan-doc steps),
  - **🔁 the DIFFERENCE vs the code sort** — a side-by-side table of the code-ordered
    top 20 next to the AI-simulated top 20, with a **Move** column showing ▲/▼ how
    far each todo moved (this is the "show me the difference" view),
  - the **proposed scorer weights** + the AI's rationale,
  - the **mis-set todos** the AI flagged for cleanup.
- **⚖ Compare Models** runs the same tuning across every available model and stacks
  each model's result so you can see **which model gives the best selection**.

### FIXED (2026-08-06) — real model list + compact single-line placement
- The model dropdown now populates from `Comserv::Model::AI` (the **same facade the
  chat-header model picker uses**), queried via a new `GET /api/focus/models`. The
  earlier version called the wrong provider (`AI2::Provider::Ollama->installed_models`)
  which returned empty on this host, so the picker showed only one model. Now every
  installed Ollama model + external (Grok/xAI) model appears, so the comparison is real.
  `api_focus/top5` also calls through `Comserv::Model::Ollama` on the configured host
  (matching the chat system), not a localhost-only provider.
- **Layout**: the AI Focus-Tune control is now a **single inline line placed directly
  under "🎯 Today's Focus Queue"** (not 3 lines in the top action bar, and not far from
  the queue). Shows `🤖 AI: Tune [model ▾] ⚖ Compare` on one row. The result panel
  renders below it, adjacent to the queue, so the diff is visible at a glance.

## Phase 7 — API surfaces the same project name + link as the web page (2026-08-15)
The web detail page (Ph detail-view fix) now shows the attached project <em>name</em> as a
clickable link, but `GET /api/todos` (the surface AI agents use to "see the app as a logged-in
user") returned only the raw numeric `project_id` — so an agent could not name or jump to the
project without a second lookup.
- **Fix:** `Comserv/lib/Comserv/Controller/Api.pm` `_todo_to_hash` now resolves the same
  `belongs_to(project)` relationship and adds two fields per todo:
  - `project_name` — the project name (`null` when none attached)
  - `project_link` — `/project/details?project_id=<id>` (`null` when none)
  `project_id` is retained for backward compatibility.
- Now an agent authenticated as a logged-in user sees the identical project name + destination
  link the browser shows — they can never disagree, because both read the same relationship.
- **Verified:** `perl -e 'use Comserv::Controller::Api'` compiles cleanly; change is confined
  to the serializer and auto-reloads on the running `:3001` process. (Live JSON not captured
  this session — auth-gated curl probe required consent.)

## Phase 8 — `/project/details` embedded cards still light-on-light + v2 inline-script removal (2026-08-15)
The card theme fix from Phase 7 (todo_card.tt → `todo_shared.css` overrides) was not actually
applied on `/project/details` because the controller's `details` action loaded only
`project-details.css` and never `todo_shared.css`. Without that include the embedded
`todo_card.tt` cards fell back to Bootstrap's white `.card` → light-on-light on the dark theme.
- **Fix (Controller/Project.pm `details`):** `additional_css` now loads **both**
  `todo_shared.css` and `project-details.css`. `project-details.css` was already theme-safe and
  is untouched — the only gap was the missing `todo_shared.css` include (the grid page and the
  day/week/month views already load it; this route did not).
- **v2 JS:** removed the inline `<script>` (AI-conversations fetch) from `root/todo/projectdetails.tt`;
  moved it to `root/static/js/project/project-conversations.js`, delegated on `[data-project-id]`,
  loaded via `root/js_load.tt` on `/project/` routes (no inline `<script>` in any js_load.tt template).
- **Project link:** the in-card Project link (`todo_card.tt` `tc.project` →
  `/project/details?project_id=<id>`) was already present and is visible again now that the card
  body is readable. No new link styling required.
- **Verified (static):** `projectdetails.tt` parses via TT (stub) with 0 real `<script>`/`<style>`;
  `node --check` passes on the new JS; grep of the three loaded CSS files for broad
  `a`/`button`/`*` color selectors → none. Live admin render pending (auth-gated).

## Working discipline — time logs are mandatory per todo
User rule (2026-08-05): every todo we work on must get a time log. Procedure:
- On START of work on a todo: `POST /api/todo/open_log` with `actor=hermes-agent`
  (never the site owner's name).
- On FINISH: `POST /api/todo/close_log` (same actor). The duration is then real elapsed.
- Identity contract: callers self-identify via `actor`; the neutral default is `api`.
  Agent work is branded `hermes-agent`, not `Shanta`.
- Backfill note: the 5 phase todos (1917-1921) were NOT logged live during the session;
  a backfilled `hermes-agent` log was added 2026-08-05 after the user asked. Going forward,
  logs are opened/closed live, not backfilled.
- Pre-existing `Shanta` logs on 1917/1918/1920 (rec 642/643/647) are NOT ours; left
  untouched per user instruction.

## Phase 6 — Consolidate all list sorting into ONE shared ranker (discovered 2026-08-05)
The Focus Queue fix (Ph1/Ph2/4b/5) exposed that sorting is reimplemented in many places and
they disagree. Today there are at least SIX independent sort implementations, server and
client, each with its own notion of "order":

### Server-side (Perl) — should all call Comserv::Util::TodoRanking::score_todo
- `lib/Comserv/Model/Todo.pm:57,86` — `order_by priority,start_date` (todo model default list)
- `lib/Comserv/Controller/Todo.pm:408` — main `/todo` index (DONE: now ranks by ap_score)
- `lib/Comserv/Controller/Todo.pm:1916` — `day.tt` calendar (DONE: now ranks by ap_score)
- `lib/Comserv/Controller/Planning.pm:539-640` — Focus Queue (canonical scorer, source of truth)
- `lib/Comserv/Controller/Apiary.pm:770,817` — separate `order_by priority` todo-like list

### Client-side (JS) — re-sorts and OVERRIDES the server order; must collapse to one
- `root/static/js/planning/daily-plan.js:272` sortTodos — Focus Queue (DONE: added `score` mode, made default)
- `root/todo/day.tt:639` reorderTimeSlot — sorts by raw `data-priority` (still ignores score)
- `root/static/js/ai-editing-widget-float.js:2142` — `.sort` on todo-ish items (separate impl)

### Goal
1. ONE ranking function: `TodoRanking::score_todo` (already exists, carries stale penalty,
   due boost, cross-blocker boost, SUPERSEDED + routine demotions). Every server list that
   shows todos calls it; no list sorts by raw `priority` anymore.
2. ONE client sort: replace the per-view raw-`priority` JS sorts (reorderTimeSlot, the
   ai-editing widget sort) with a shared `score` sort that reads `data-score` (the server's
   `ap_score`). The Focus Queue `score` mode is the template to reuse.
3. Nested/secondary sorts expressed as a single ordered tuple (score, then priority, then
   due, then project) so every view orders identically — "most sorting done in the
   application" as the user requested, with the client only breaking ties / honoring an
   explicit user-chosen secondary sort.
4. **SHARED, SITE-AGNOSTIC toolkit (added 2026-08-05).** `Comserv::Util::FocusRanking`
   (new) owns `passes_filters()` — a pure Role/Site/Project predicate mirroring the Focus
   Queue client filter, with NO `is_csc` gating. Any controller can reuse it: e.g. BMaster
   can rank/filter its calendar todos, and weather (via an external feed) is a natural
   FUTURE scoring factor to add to `TodoRanking::score_todo` so calendar views surface
   weather-sensitive work. The toolkit is deliberately not confined to CSC.
   **MIGRATION DONE (2026-08-05):** `Planning.pm` Focus Queue loop now builds a `filter_ctx`
   from `$filter_site`/`$filter_project` and calls `FocusRanking::passes_filters` server-side
   (before `push @scored`), so the CSC page consumes the shared predicate. Unfiltered
   behavior unchanged; when a site/project filter is active the server drops non-matching rows
   (the client JS still refines). `FocusRanking.pm` syntax OK; `passes_filters` verified.

### GATE
- `grep -rn "order_by => { -asc => 'priority'" lib/` and `order_by priority,start_date`
  returns zero todo-list hits (only legitimate non-todo sort_order uses remain).
- Every JS view that renders todos sorts by `data-score` by default.
- Spot-check: main /todo, Focus Queue, day calendar, and Apiary list all open with the same
  top 5 for a given CSC admin.

NOTE: this phase is documentation/scope only in this plan; implementing it is a follow-on
effort (no todo rows created per user instruction — track in planning, not as new todos
unless the user later asks).

## References
- Planning skill (Rule 4c duplicate-project search, Rule 1 plan gitignore negation).
- `Comserv/lib/Comserv/Controller/Planning.pm:538-659` (Focus Queue scorer).
- `Comserv/lib/Comserv/Controller/Todo.pm:406-409` (main list order_by).
