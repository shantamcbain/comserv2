---
title: "Documentation System Standard"
description: "The single authoritative standard for how Comserv stores, categorizes, displays, and gates documentation. Replaces all prior documentation-system plans."
roles: "admin,developer"
category: "documentation"
page_version: "1.00"
last_updated: "Thu Jul 30 2026"
site_specific: "false"
author: "Shanta"
status: "Active"
---

# Documentation System Standard

> This is the **single source of truth** for how documentation works in Comserv.
> It supersedes DOC-ROLE-001, the DOCSYS refactoring plan, "Documentation System Audit
> & Planning", and `DOCUMENTATION_LINK_STANDARDS.md`. Those are retired (see History).

## Why this standard exists

The documentation system accumulated **five overlapping mechanisms** because every prior
"fix" added a layer on top of the old one instead of removing it:

1. **SQL layer** — `documentationmetadataindex` + `documentationroleaccess` tables exist as
   DBIx Result classes and are registered in `DBSchemaManager`, but no controller ever read
   them. Abandoned.
2. **JSON config layer** — `DocumentationConfig.json` (shipped) + a runtime session overlay.
   Three files, three schemas. This was the de-facto live store.
3. **META block convention** — a `[% META ... %]` directive (title, description, roles,
   category, page_version, last_updated) in the live master template
   `DocumentationTtTemplate.tt`; historically also half-parsed from disk by `ScanMethods.pm`.
   The META block stays as the per-file authoring standard, but its category/role values
   are now mirrored into SQL by the indexer (see S1/S5) rather than read ad-hoc.
4. **Ad-hoc `.md` files** — ~40 of them, no enforced indexing, referenced inconsistently.
5. **A graveyard of prior plans** — each spawned a new mechanism without retiring the old.

The rule below stops that cycle: **adopt a new approach and delete the old one in the same
change.**

## The standard (S1–S7)

- **S1 — One source of truth for metadata.** Categorization, role visibility, and search
  live ONLY in SQL (`documentationmetadataindex` for catalog/search/roles;
  `documentationroleaccess` as a DEFAULTS seed only). No JSON config, no META block, no
  filesystem-scan-derived metadata is authoritative.
- **S2 — One reader.** `Comserv::Util::DocumentationConfig` is the ONLY module that reads doc
  metadata, and it reads from SQL. All doc controllers (`Documentation`, `ConfigBased`,
  `Config`, `AutoDiscovery`, `ScanMethods`) go through it. A second doc-data source is a bug.
- **S3 — File format by purpose (no format sprawl):**
  - `.tt` = pages rendered INSIDE the app (needs theme, navigation, role-aware chrome). Use
    for user/role/admin/developer guides, system docs, index pages.
  - `.md` = reference content consumed by the AI assistant or read by humans directly. The
    AI prefers these (no Template Toolkit markup to strip). They may link out to `.tt` pages
    but do not need app navigation.
  - A doc's `file_type` column records `tt` or `md`. Both are first-class; do not convert one
    format to the other just to unify.
- **S4 — Routing is flat, stable, and extensionless.** There is ONE catch-all route
  (`/Documentation/<page>`) — no separate route per document. The `<page>` is a **stable
  page key** (e.g. `admin/schema-compare-guide`, `DocumentationTtTemplate`), NOT the disk
  path. The catalog stores the real `path` (e.g. `Documentation/admin/schema-compare-guide.tt`)
  and resolves the key → file. This avoids a new route per doc and survives rapid renames.
  Never rename a page key without a redirect entry, and keep the `path` in sync via the
  indexer. (Mirrors the `DocumentationTtTemplate.tt` rule: links are `/Documentation/FILENAME`,
  no subdirs, no `.tt` suffix.)
- **S5 — Metadata is declared once, by the indexer.** When a `.tt`/`.md` is added or changed,
  its `documentationmetadataindex` row (title, categories, role_access, excerpt,
  content_hash) is created/updated by the indexer. Authors do NOT hand-edit JSON or META
  blocks for categorization.
- **S6 — No orphaned mechanisms.** When adopting a new approach, the old one is deleted in
  the SAME change (code + config + the superseded plan doc). A plan that adds without
  removing is incomplete.
- **S7 — The index is generated, not curated.** A single indexer scans
  `root/Documentation/**` and upserts rows into `documentationmetadataindex`, computing
  `content_hash` so stale rows are detectable. Manual entry (the old `add_to_config` UI) is
  removed; any remaining admin UI calls the indexer, it does not edit a JSON file.

## How SQL locates files (and how roles work)

There are two separate concerns; do not tangle them:

- **File location** is the `file_path` column. The controller queries
  `documentationmetadataindex` and gets the list of files, titles, and categories. That is
  the catalog. No directory scanning, no JSON.
- **Visibility (roles)** was duplicated across two dead schemas. It is now ONE gate:
  - `documentationmetadataindex.role_access` — a JSON array **on the row** for that one file,
    e.g. `["admin","developer"]`. This is the live gate.
  - `documentationroleaccess` — a separate table of coarse DEFAULT rules: `role` +
    `doc_section_pattern` (a glob like `admin/*`) + `can_access`. The indexer applies these
    as defaults (anything under `admin/*` → `[admin, developer]`), but the per-doc
    `role_access` column wins. One gate, not two.

## How `.md` navigation works (SQL is the catalog, the file holds the links)

- **SQL `documentationmetadataindex` is the catalog:** it lists every file (both `.tt` and
  `.md`), its title, category, role, and has a `searchable_text` column plus an
  `ai_citations` relationship to `AiMessage`. It tells you WHAT exists and HOW to find it
  (search, category listings, related docs).
- **Cross-links live in the file content.** A `.md` that mentions another doc uses a normal
  markdown link, e.g. `[Schema Compare Guide](/Documentation/admin/schema-compare-guide.tt)`.
  When the `.md` is rendered (in-app or surfaced by the AI), that link is clickable, so a
  reader can jump to the mentioned file. The SQL table is NOT the link store.
- **AI-to-doc:** when the AI references a doc, it is surfaced as a clickable link to
  `/Documentation/<path>` (using the `ai_citations` relationship), so the user opens the full
  doc to read. This is the "chat takes the user to the document" behavior.

## Target architecture (one system)

```
root/Documentation/**
   ├── *.tt   (app-rendered pages: theme + nav + role chrome)
   └── *.md   (AI/human reference; optional cross-links to .tt)

MySQL (Ency)                         Perl
documentationmetadataindex  ──────► Comserv::Util::DocumentationConfig  (ONLY reader)
documentationroleaccess     ──────►   (DEFAULTS seed for role_access)
                                        │
                                        ▼
                          Comserv::Controller::Documentation (+ ConfigBased/Config/AutoDiscovery/ScanMethods)
                                        │
                                        ▼
                          /Documentation/<rel-path>   (flat routing, S4)

Indexer (on deploy + nightly cron): scans disk → upserts rows (S5, S7)
```

## Authoring rules (do this, not the old ways)

- New in-app guided page → create a `.tt` with a META block (title, description, roles,
  category, page_version, last_updated, site_specific, author, status). The indexer picks
  it up.
- New reference/explainer doc → create a `.md`. The indexer picks it up; link to related
  `.tt` pages where navigation helps.
- Do NOT edit `DocumentationConfig.json` or any META block for categorization — the indexer
  owns metadata.
- Do NOT start a new documentation-system plan without retiring the previous one (S6).

## History (retired plans)

- DOC-ROLE-001 ("Documentation System Improvements", `DevelopmentPlans.tt`) — replaced by S1–S7.
- DOCSYS: Documentation System Refactoring — replaced.
- "Documentation System Audit & Planning" / `DocumentationConfigAuditFindings.tt` — replaced.
- `DOCUMENTATION_LINK_STANDARDS.md` — replaced by S4 (flat stable routing).

The full implementation checklist (steps, resumable, non-breaking) lives in the project plan
file `.hermes/plans/2026-07-30_061000-documentation-system-standard.md`. This document is the
standard; the plan is the work order.
