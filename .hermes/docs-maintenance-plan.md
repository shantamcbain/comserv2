# Documentation Maintenance Plan — Comserv2

Owned by: the Documentation expert (`.hermes.md` role).
Status: active. Last refreshed: 2026-08-25 (branch `Documentation`).

Purpose: keep every documentation surface accurate, consistent, and in sync with the
code — and to give a repeatable process so the docs don't drift again.

---

## 1. The documentation surfaces (what "in order" means)

| Surface | Path / location | Format | Verified by |
|---|---|---|---|
| Rendered user/admin docs | `Comserv/root/Documentation/<Module>/*.tt`, `Documentation/<Module>/*.tt` | `.tt` + YAML META | In-app `/Documentation/...` + theme check |
| Module landing pages | `…/<Module>/index.tt` | `.tt` + META | Manual review |
| AI-context stubs | `Documentation/<Module>/SUMMARY.md` (<2KB) | markdown | Grep/spot check |
| Changelog | per-entry `.inc` fragments | `Comserv/root/Documentation/changelog/entries/` | Appended via new file; `/Documentation/CHANGELOG` is the generated reader |
| Cross-cutting guidance | `.hermes.md` (this role) | markdown | This plan |
| Per-session handoffs | `Comserv/root/Documentation/session_history/*.md` | markdown | N/A (archive) |
| Agent routing | `Comserv/root/static/config/agents.json` | JSON | `jq` validate |

**Invariant:** every rendered page is a `.tt` with a `PageVersion` header and a `META`
block, themed entirely with `var(--*)` (no hardcoded colors). AI-context files stay
under ~2KB and point at real paths.

---

## 2. Initial audit (2026-08-25) — measured, not guessed

Run from repo root on the `Documentation` branch.

### 2.1 Controller package/filename mismatches
```
MISMATCH Comserv/lib/Comserv/Controller/AI/AIAdmin.pm    -> Comserv::AI::AIAdmin    (want Comserv::Controller::AI::AIAdmin)
MISMATCH Comserv/lib/Comserv/Controller/AI/AIPlanning.pm -> Comserv::AI::AIPlanning (want Comserv::Controller::AI::AIPlanning)
```
**Assessment:** these are *intentional* Catalyst namespace declarations (the `AI`
controllers are mounted under `Comserv::AI`, not `Comserv::Controller::AI`). Do **not**
"fix" the package line without confirming the route mount — listed here for awareness,
not as a defect to auto-correct.

### 2.2 Two disconnected documentation trees
- `Comserv/root/Documentation/` — **827 files** (606 `.tt` + 49 `.md` + 149 `.inc`). This
  is the **single source of rendered truth** (scanned by `Documentation.pm` →
  `ScanMethods`, categories driven by `documentation_config.json` + a DB overlay).
- `Documentation/` — only 4 dirs; `Accounting`/`Inventory` mirror the rendered tree,
  but `DailyPlans` and `script` are unrelated to AI-context. Agents/tooling do **not**
  treat these as one system. AGENTS.md's assumption of `Documentation/<Module>/SUMMARY.md`
  stubs is not met (see 2.4).

### 2.3 Rendered `.tt` compliance (measured, 606 files)
- `META` block present: **455 (75%)** → ~120 pages render without a title/META.
- `PageVersion` header present: **487 (80%)**.
- `var(--*)` theming present: **208 (34%)** → **398 `.tt` are hardcoded-color / unthemed**
  and break on non-default themes. This is the largest compliance gap.

### 2.4 Dead `SUMMARY.md` mechanism
**Zero `SUMMARY.md` files exist anywhere in the repo**, yet AGENTS.md mandates them per
module and `sync-docs.sh` is built to create/maintain them. The contract is currently a
lie. Resolution (revive-by-generation vs retire) is the top item in the improvement plan.

### 2.5 Stray `.md` + stale paths + module coverage
- **49** stray `.md` under the rendered tree (should be `.tt` or archived; `session_history/`
  `.md` are a legitimate archive).
- **62** `.tt` files still contain a stale `/home/shanta/PycharmProjects/comserv2/…` path
  (inside `PageVersion`/references — cosmetic but wrong).
- **24 of 34** top-level modules have **no `index.tt`** landing page.
- `AI_ASSISTANT_GUIDELINES.tt` referenced a non-existent `Documantation.pm` (fixed).
- `README.tt` / `AGENTS.md` point at legacy `Comserv/docs/` paths that no longer exist.

### 2.6 Healthy sub-system (the model to follow)
Changelog = **149 per-entry `.inc` fragments** under `changelog/entries/`, organized by
date (2024:12, 2025:68, 2026:69), present on every branch, parse-on-read, never
merge-collide. The rendered-doc tree should adopt the same "single source + generated
reader" discipline.

> **Full analysis + phased plan:** see `.hermes/docs-improvement-plan.md`.

---

## 3. Standing process (do every session)

1. **On any code/doc change:** add a per-entry changelog **fragment** at
   `Comserv/root/Documentation/changelog/entries/YYYY-MM-DD-slug.inc`
   (wrapper `<div id="slug" class="cl-entry">`, `<h3>` date-title, `doc-body`
   paragraphs). Do **not** hand-edit the root `CHANGELOG.tt` — it is a generated
   reader. This dir exists on every branch, so the note is available everywhere
   and never collides on merge.
2. **On any doc change:** ensure `.tt` + META + `PageVersion`; update the sibling
   `SUMMARY.md` if the module's AI-facing facts changed.
3. **After controller/model edits:** run
   `bash Documentation/script/sync-docs.sh --dry-run`, then for real if the auto-index
   is stale.
4. **Before claiming done:** re-run the audits in §2 (controller mismatch scan, stray
   `.md` grep, stale-path grep) and confirm no new drift.

---

## 4. Backlog (prioritized)

Driven by the audit in §2. The full phased plan (with phases 0–5) is in
`.hermes/docs-improvement-plan.md`.

| # | Item | Effort | Risk | Owner |
|---|---|---|---|---|
| P1 | **Theming sweep** — migrate 398 unthemed `.tt` files to `var(--*)` (highest-impact compliance gap) | L | low | docs |
| P1 | **Resolve dead `SUMMARY.md` mechanism** — generate stubs from META, or formally retire from AGENTS.md | M | low | docs |
| P1 | **Unify the two doc trees** — declare `Comserv/root/Documentation/` the single source; repurpose/retire `Documentation/` | M | med | docs |
| P1 | Fix `Documantation.pm` typo in `AI_ASSISTANT_GUIDELINES.tt` | S | none | docs |
| P2 | Backfill `META`/`PageVersion` on ~120 missing `.tt` pages | M | low | docs |
| P2 | Add `index.tt` to the 24 modules lacking one | M | low | docs |
| P2 | Convert/archive 49 stray `.md` under rendered tree | M | low | docs |
| P3 | Scrub 62 stale `PycharmProjects` paths | M | low | docs |
| P3 | Correct `README.tt` / `AGENTS.md` legacy `Comserv/docs/` references | S | none | docs |
| P3 | Add a docs lint to CI (META, PageVersion, theming, stray `.md`) | M | med | docs+dev |

Items marked P1/P2 are safe, mechanical, and doc-only — good first commits on this
branch. P3 needs a quick owner sign-off.

---

## 5. Schedule (cadence)

- **Every session:** §3 standing process.
- **Weekly:** re-run §2 audits; update this plan's "Last refreshed" date; sweep the
  P2 backlog one batch at a time.
- **On merge to main:** confirm `sync-docs.sh` ran (post-commit hook) and every change
  since the last release has a `changelog/entries/*.inc` fragment (the root
  `CHANGELOG.tt` is a generated reader, not hand-edited).

---

## 6. Definition of "done" for documentation

- Every rendered page renders on all themes (no hardcoded colors).
- Each change since last release has a changelog fragment under `changelog/entries/`
  (root `CHANGELOG.tt` is a generated reader, not edited by hand).
- No controller/model change is undocumented (sync hook green).
- No dead path/reference in the top-level docs.
- This plan's audit section is no more than one week stale.
