# V2 Migration Plan (AI / assistant reference)

**Project code:** V2MIG (proj #259)
**Parent project:** none — this is a top-level plan
**Phases (sub-projects, parent_id = 259):** #260 V2MIG-P1, #261 V2MIG-P2, #262 V2MIG-P3, #263 V2MIG-P4, #264 V2MIG-P5
**Site:** CSC
**Status:** In-Process
**Standard:** follows [Planning Language Standard](/Documentation/PlanningLanguageStandard) — PHASE = sub-project, STEP = todo, GATE = done-when
**Coordinator:** [Comserv2 Master Plan](/Documentation/MASTER_PLAN) — Project #259 V2MIG
**Sibling (human view):** [V2MigrationPlan.tt](/Documentation/V2MigrationPlan)
**Deliverable (one line):** migrate the whole app to the v2 standard (theme classes only / no inline style, `js_load.tt` data-* delegation / no inline script, documentation-standard S1-S7), with the Planning page fixed IN LOCKSTEP with its migration.

## Why this is its own project
V2 migration touches almost every `.tt` and a large number of other files. It must be tracked as a first-class plan, not a sub-bullet of another project. The current dire state of the **Planning page** is a direct symptom of v2 work NOT being done at the same time the page was improved — so phase **P4** makes the Planning-page fix ship together with its v2 migration.

## What "v2" means per .tt (the gate)
- No inline `style="..."` and no hardcoded colours — theme classes / `var(--*)` only.
- No inline `<script>` in templates using `js_load.tt`; JS wired through `js_load.tt` with `data-*` delegation.
- Documentation pages follow S1–S7 (metadata in SQL, one reader, flat `/Documentation/<path>` routes, indexer-owned metadata).
- Cross-plan changes raised on the owning plan, never absorbed.

## Phases
- **V2MIG-P1 (#260)** — Baseline & standards: write the v2 standard + a CI/lint gate that fails non-compliant `.tt`. GATE: standard published; automated check blocks a non-compliant `.tt`.
- **V2MIG-P2 (#261)** — Core/shared `.tt` (layout, nav, admin shell): highest blast radius, do first. GATE: shared shell renders theme-compliant, zero inline style.
- **V2MIG-P3 (#262)** — Feature `.tt` waves: migrate feature templates in dependency order (the bulk). GATE: every feature `.tt` passes the P1 gate.
- **V2MIG-P4 (#263)** — Planning page IN LOCKSTEP: fix the Planning page together with its v2 migration (the work skipped before). GATE: planning page + its v2 migration ship in the same change, verified in-browser.
- **V2MIG-P5 (#264)** — Sync & verify: cross-link, documentation sync, full verification. Absorbs the former AIMPS-P5 "v2 Migration & Documentation Sync" intent. GATE: docs synced; all `.tt` green on the P1 gate.

## Source of truth
The DB `projects` rows (#259 + #260–264) are the source of truth. Steps live there as todos. This `.md` is the AI/assistant-readable view; the `.tt` is the human in-app view.
