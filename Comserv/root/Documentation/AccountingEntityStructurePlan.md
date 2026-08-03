# Accounting Entity Structure & Consolidation Plan (ACCENT)

**Status:** DRAFT — for review. No code written against this yet.
**Created:** 2026-08-02
**Revised:** 2026-08-02 — §3.2, §4.1, §4.3 rewritten and **§4.4 added** following statutory research
against CRA RC4088(E) Rev.23. Open questions **O1 and O3 closed**; **O6 added**. New §11 records a
seed defect found during that research (not fixed).
**Related:** `/Documentation/AccountingPostgresMigrationPlan` (ACCPG),
`/Documentation/AccountingOnboardingPlan` (ACCON)
**Data:** `root/config/gifi_codes.json` — 764 GIFI items, source-tagged.

> ### Headline findings from the 2026-08-02 research
>
> 1. **GIFI does not apply today.** It is for corporations (T2) and partnerships (T5013). Every
>    owner entity is a sole-proprietor DBA filing **T2125**. `gifi_accno` is carve-out
>    infrastructure, not present compliance (§4.4.1).
> 2. **BMaster must be built on the GIFI farm block (9370–9899), not the business block.** CRA item
>    **9470** names *"apiary operation"* and *"honey products"* explicitly (§4.4.3). This is a
>    structural change to the archetype, not a numbering detail.
> 3. **CRA prescribes no chart-of-accounts numbering convention** — internal `accno` is the
>    system's own free choice. This unblocks O5.

---

## 0. Why this plan exists

ACCPG isolates each SiteName's accounting into its own PostgreSQL database. ACCON onboards a
business into working books. Neither answers the question that falls out of the actual entity
structure:

> Shanta is one legal person, a sole proprietor, doing business as CSC, BMaster, 3D, USBM and
> VE7TIT. Shanta funds all of them. None currently earns outside income. There is one tax filing.
> **So how do five separate sets of books produce the one picture that filing needs?**

This plan defines that: the inter-entity money flow, and the consolidation read.

### 0.1 The rejected alternative, and why

The obvious reading of "one legal entity, one tax return" is: don't split the books at all. Track
the five as **cost centres** (`department` / `project`, both already present in the SQL-Ledger
schema we cloned) inside one personal ledger.

That was proposed and **rejected**, for two reasons that outweigh it:

1. **Separability.** These entities are expected to change status. USBM may evolve into a school.
   BMaster may split into a non-profit devoted to teaching beekeeping. Any of them may be sold off
   as it grows. Blended into one personal ledger, a carve-out becomes years of disentangling shared
   history. As separate books from day one, a carve-out is a handover. The owner has also named
   succession explicitly — there is no telling how long he will want to, or be able to, run things.
   Separability is therefore a **requirement**, not an optimisation.

2. **Dogfooding.** Standing the entities up as separate books that report upward is the test case
   that finds the bugs — on the owner's own data, where a defect costs an afternoon. The
   alternative is discovering the same defects in an early adopter's live accounting records. Stated
   directly by the owner: *"I don't want to be debugging code for early adopters with their
   accounting information."*

The extra structure is therefore deliberate. It is more than today's tax situation strictly
requires, and that is the point.

### 0.2 Scope boundary — client-owned sites

This plan governs **the owner's own entities only**. A SiteName owned by an external client is
outside it: their books are theirs, their dealings with their revenue agency are their business, and
their data must never mix with the owner's. The per-site PostgreSQL isolation ACCPG builds is what
enforces that boundary.

---

## 1. Current state (2026-08, stated by the owner)

| Fact | Consequence for this plan |
|---|---|
| Shanta is a sole proprietor; CSC, BMaster, 3D, USBM, VE7TIT are DBAs, not separate legal persons | One tax filing today. Consolidation is a **reporting** obligation, not a legal-entity consolidation. |
| Shanta pays all costs incurred by the other entities | Every entity has a funding inflow from the owner that must be recorded on both sides. |
| No entity currently earns outside income | Revenue-side complexity (inter-entity sales, transfer pricing) is **not yet in scope**. It will be. |
| No accounting is being done yet; no real revenue to track | **Greenfield.** No legacy chart to preserve. Standards can be followed from the start rather than retrofitted. |
| This will change over time, possibly including selling entities off | Design for evolution. Do not hardcode "five DBAs of one proprietor". |

> **Not verified by the agent.** Every row above is the owner's description of his own arrangement.
> This plan records it; it does not audit it.

---

## 2. Principles

| # | Principle |
|---|---|
| E1 | **Truthful recording over convenient recording.** The books record what actually happened. Where a treatment is ambiguous, record the facts and leave the treatment to the accountant. |
| E2 | **Separable by construction.** Every entity's books must be carve-out-ready at all times. No shared row, no shared sequence, no report that cannot be run for one entity alone. |
| E3 | **Both sides, always.** Money moving between the owner and an entity is recorded in both ledgers. A one-sided entry is a bug. |
| E4 | **Consolidation is a read, not a write.** The consolidated picture is derived. It never mutates an entity's books. |
| E5 | **Client data never consolidates.** The roll-up query is scoped to owner-controlled SiteNames by an explicit allow-list, never by "all sites". |
| E6 | **The agent does not give tax advice.** Structure and arithmetic, yes. Whether a given flow is a loan or a capital contribution, and how it is reported — accountant's call. |

---

## 3. Money flow — owner-draw model

Chosen by the owner over a periodic-journal-push alternative:

> *"I put in money as a loan and get money out as a draw."*

### 3.1 The two directions

```
  Shanta (personal books)                    Entity books (e.g. BMaster)
  ───────────────────────                    ───────────────────────────

  FUNDING IN  ──────────────────────────────────────────────────────────
  Cr  Cash/Bank                              Dr  Cash/Bank
  Dr  Loan receivable — BMaster              Cr  Loan from owner
      (asset: owed back to Shanta)               (liability: owed to Shanta)

  DRAW OUT  ────────────────────────────────────────────────────────────
  Dr  Cash/Bank                              Cr  Cash/Bank
  Cr  Loan receivable — BMaster              Dr  Loan from owner
      (reduces the balance owed)                 (reduces the balance owed)
```

The two sides are mirror images. **The owner's `Loan receivable — <entity>` balance must at all
times equal that entity's `Loan from owner` balance.** That equality is the reconciliation check
(§5.2) and the single most important integrity property in this plan.

### 3.2 Accounts required

In **each entity's** chart:

| accno (proposed) | Description | category | Notes |
|---|---|---|---|
| 2900 | Loan from owner | L | Liability. Balance owed back to the proprietor. |
| 3000 | Owner's equity | Q | Already in the current seed. |
| 3200 | Owner draws | Q | Contra-equity. Withdrawals. |

In the **owner's** chart, one receivable per entity:

| accno (proposed) | Description | category |
|---|---|---|
| 1400 | Loan receivable — CSC | A |
| 1410 | Loan receivable — BMaster | A |
| 1420 | Loan receivable — 3D | A |
| 1430 | Loan receivable — USBM | A |
| 1440 | Loan receivable — VE7TIT | A |

**Numbering status (researched 2026-08-02, O1 closed).** The internal `accno` values above are the
system's own numbering and are *not* dictated by any statutory scheme — CRA does not prescribe a
chart-of-accounts numbering convention. What CRA prescribes is the **GIFI code** an account maps to
at filing time, carried in the separate `gifi_accno` column (§4.4). The two are independent: internal
accno stays stable and human-friendly; `gifi_accno` carries the statutory mapping.

GIFI mappings for the owner-draw accounts, from RC4088(E) Rev.23 Appendix A:

| accno | Description | category | `gifi_accno` | GIFI item |
|---|---|---|---|---|
| 2900 | Loan from owner | L | `2780` | Due to shareholder(s)/director(s) — current. Long-term equivalent is `3260`. |
| 3000 | Owner's equity | Q | `3500` | Common shares (owner capital) |
| 3200 | Owner draws | Q | `3700` | Dividends declared |
| 1400–1440 | Loan receivable — *entity* | A | `1301` | Due from individual shareholder(s) (`1300` is the parent item) |

> **Caveat, stated deliberately.** GIFI's shareholder/director vocabulary is corporate. For a sole
> proprietor these codes are the *closest available* items, not exact matches — which is consistent
> with §3.4: a sole proprietor does not file GIFI at all today (§4.4). These mappings exist so the
> data is ready if an entity incorporates, and should be reviewed by the owner's accountant at that
> point rather than treated as settled.

### 3.3 Recording discipline

Every owner-funded payment is one logical transaction with two ledger entries. The system must make
the paired entry, not rely on the operator remembering. A funding entry that lands in only one
ledger is the defect this design is most exposed to — §5.2 is how it gets caught.

### 3.4 Legal caveat

Loan-in / draw-out between a sole proprietor and their own DBAs is a conventional arrangement.
**Whether these are genuinely loans or capital contributions, and how each is reported, is a
question for the owner's accountant** — the system records the facts accurately and takes no
position on the treatment (E1, E6).

---

## 4. Chart of accounts — two axes

Superseding the flat five-archetype list in ACCON §4. Not one list — a **base** plus **overlays**.

### 4.1 Base archetype — one per entity, by business model

| Archetype | Entity | Statutory basis (§4.4) |
|---|---|---|
| Service & consulting | CSC — hosting, programming, helpdesk | GIFI 8000–9368 business block |
| **Agriculture & apiary** | BMaster — beekeeping, beeyard | **GIFI 9370–9899 farm block** (§4.4.3) |
| Maker & light manufacturing | 3D — print farm | GIFI 8000–9368 business block |
| Non-profit / co-op | USBM — school | GIFI + Appendix C NPO mapping (§4.4.4) |
| Sole proprietor / personal | Shanta, VE7TIT (ham radio hobby) | T2125 — **lines not yet obtained**, §7 O6 |

**Retired as a base archetype: "retail / e-commerce"** (ACCON §4 lists it). E-commerce is a
capability a site switches on, not a business model any entity *is*. It becomes an overlay (§4.2).

### 4.2 Overlays — applied on top, driven by what the site actually has

**Teaching overlay** — applies to BMaster, 3D, USBM. Split into two blocks, because USBM takes
**both** tuition and grant/donation funding and they must not be commingled:

- *Earned*: tuition / course fee revenue; student deposits held as a **liability** until the course
  is delivered (unearned revenue); instructor cost.
- *Funded*: grant income; donation income; restricted-fund tracking; mentoring program expense.

**E-commerce overlay** — applied when the site has the `ecommerce` site-module enabled. That module
already exists (`Controller/Admin/SiteModules.pm:266`, "E-Commerce & Store", route `/shop`), so
this is a query, not a new concept. Accounts: merchant/processor fees, shipping income and expense,
sales tax collected, refunds and chargebacks, COGS on goods sold.

Candidates: CSC, BMaster, 3D, USBM. **Not** Shanta, **not** VE7TIT.

### 4.3 Existing schema this must respect

The PostgreSQL `chart` table is cloned from SQL-Ledger / LedgerSMB and already provides:

| Column | Significance |
|---|---|
| `charttype` A/H | account vs heading |
| `category` A/L/Q/I/E | asset / liability / equity / income / expense |
| `heading` (self-FK) | hierarchy |
| `link` | LedgerSMB link semantics (AR, AP, IC, AR_amount, IC_sale, IC_cogs …) — controls which dropdowns an account appears in |
| `gifi_accno` | **standardised statutory account code — present but unused by the current seed** |

Templates must emit rows that populate these columns correctly rather than inventing a parallel
shape. `gifi_accno` is populated per §4.4.

**Verified 2026-08-02:** nothing under `lib/` reads `link`, `charttype`, `accno` or `gifi_accno` —
grepped, zero hits. These are inert seed columns today. That means the mapping in §4.4 can be
defined and seeded **now with zero regression risk**, before any Perl consumes them.

---

### 4.4 GIFI — what it actually is, and who must file it

Researched 2026-08-02 directly from **CRA RC4088(E) Rev. 23**, *General Index of Financial
Information*. This section closes O1 and O3.

### 4.4.1 GIFI does not apply to the owner today

RC4088 is explicit: **GIFI is for corporations filing a T2 and partnerships filing a T5013.**
A sole proprietor reports business income on **T2125, Statement of Business or Professional
Activities**, filed with the T1 — not via GIFI.

Every entity in §1 is currently a sole-proprietor DBA. **Therefore no GIFI filing obligation exists
right now.** This corrects an assumption that ran through the earlier draft of this plan.

**This does not make `gifi_accno` optional.** It changes *why* it is populated:

> A populated `gifi_accno` column is what turns an entity incorporation or carve-out (§5.3) into a
> data migration instead of a re-keying project. It is forward-looking infrastructure for exactly
> the separability requirement in §0.1 — not present-day compliance.

Priority consequence: populating `gifi_accno` is **not a Ph.1 blocker**. It should be seeded with
the templates because doing it later means revisiting every chart.

### 4.4.2 Verified band structure

From Appendix A. These are CRA's bands, not a convention this project chose:

| Band | Content |
|---|---|
| 1000–2599 | Assets (current, capital, long-term) |
| 2600–3499 | Liabilities (current, long-term) |
| 3500–3849 | Equity / retained earnings |
| 7000–7020 | Other comprehensive income |
| 8000–8299 | Revenue (non-farming) |
| 8300–9368 | Expenses (non-farming) |
| **9370–9899** | **Farming revenue and expenses — a parallel, self-contained block** |
| 9970–9999 | Net income / taxes / extraordinary items |

The complete 764-item list is stored at **`root/config/gifi_codes.json`**, tagged with source
(`RC4088(E) Rev.23`) and retrieval date. It is **data, not code** (ACCON principle N8), and is
regenerable from the CRA page.

### 4.4.3 BMaster belongs in the farming block — a structural correction

GIFI item **9470**, verbatim from Appendix A:

> *"Livestock and animal products revenue — revenue received from animal pelts, **apiary operation**,
> bison, chinchilla, deer, dog, elk, fox, goats, **honey products**, mink, market livestock income,
> rabbit, and wool."*

Apiary and honey are named explicitly, in the farming band, with a full expense set beneath:

| GIFI | Item | Relevance to BMaster |
|---|---|---|
| 9470 | Livestock and animal products revenue | **Honey / apiary sales** |
| 9600 | Other farm revenues | Sundry |
| 9601 | Custom or contract work | Pollination services |
| 9711 | Feed, supplements, straw, and bedding | Sugar / winter feed |
| 9713 | Veterinary fees, medicine, and breeding fees | Mite treatment, queen purchases |
| 9714 | Minerals and salts | Supplements |
| 9806 | Marketing board fees | Provincial beekeeper association levies |
| 9659 / 9898 / 9899 | Total farm revenue / expenses / **net farm income** | Farm block totals |

**Consequence — this is a change to §4.1, not a numbering detail.** The *Agriculture & apiary*
archetype must be built on the **9370–9899 farm block**, with `9899 Net farm income` as its
bottom line, **not** on the generic 8000/9000 business block. A farming entity's net income flows
into `9970` separately from non-farm income (`9369`). Building BMaster on the business block would
produce a chart that cannot map to a farm return at all.

### 4.4.4 USBM — Appendix C is a ready-made NPO mapping

RC4088 **Appendix C** exists specifically to map non-profit terminology to GIFI. It answers the
restricted-funds question in §4.2 directly rather than by inference:

| NPO term | GIFI | GIFI item |
|---|---|---|
| Membership dues or fees | 8221 | Membership fees |
| Gifts / donations | 8223 | Gifts |
| Revenue from organizational activities | 8224 | Gross sales and revenues from organizational activities |
| Grants (federal / provincial / municipal) | **8242** | Subsidies and grants |
| Amounts receivable from members | 1073 | Amounts receivable from members of NPOs |
| Amounts payable to members | 2630 | Amounts payable to members of NPOs |
| Total receipts | 8299 | Total revenue |

**Restricted funds — the mechanism.** CRA models fund accounting through **interfund transfer**,
and the code depends on where it is shown:

| GIFI | When |
|---|---|
| **3745** | Interfund transfer shown **in retained earnings** |
| **9286** | Interfund transfer shown **on the income statement** |

That distinction *is* the restricted-fund treatment in CRA's terms. Appendix C also confirms the
terminology equivalences the USBM template should use: *fund balances / net assets / reserves* →
shareholder equity; *excess of revenues over expenses* → net non-farming income.

### 4.4.5 Template obligation

Each archetype template emits `gifi_accno` per account. Where no exact GIFI item exists (common for
sole-proprietor equity, §3.2), the template records the **nearest** item and flags it for accountant
review rather than leaving it blank or inventing a code.

> **Still open — T2125 line mapping.** The *Sole proprietor / personal* archetype should map to
> **T2125 line numbers**, not GIFI, since that is the form actually filed. Those line numbers were
> **not** obtained: canada.ca blocks direct fetch from the agent sandbox and T2125 is a PDF. See §7 O6.

---

## 5. Consolidation — the periodic read

> *"the regular or monthly reads can keep things current so look at my personal account give a
> summary of all entities."*

### 5.1 Shape

A **read-only** report (E4). It queries each owner-controlled entity's PostgreSQL accounting
database, and renders a combined picture from the owner's vantage point. It writes nothing to any
entity's books.

Per entity: revenue, expenses, net position, loan balance owed to the owner, and period movement.
Plus a combined total for the tax-time picture.

Scoped by an **explicit allow-list of owner-controlled SiteNames** (E5). Never "every site in the
registry" — that would sweep in client books.

### 5.2 The reconciliation check

For every entity, assert:

```
owner.  Loan receivable — <entity>   ==   entity. Loan from owner
```

Any discrepancy is reported prominently, per entity, with the difference. This is what catches a
funding entry that landed on only one side (§3.3), and it is the reason the consolidation report
earns its keep beyond convenience.

### 5.3 The split-off signal

A stated purpose of the report: *"This information will be useful to know when to split off an
entity to simplify accounting."*

So it must show, per entity, the trend that informs that judgement — is it earning outside income
yet, is it still wholly owner-funded, is its expense base growing. Exact metrics: **open, §7 O4.**

### 5.4 Cadence

Monthly, per the owner. Whether that is a scheduled job or an on-demand report is an
implementation question, not a plan question.

---

## 6. External users — import / export

Distinct from the owner's entities, and distinct from a new business being onboarded.

A client who already runs accounting elsewhere must **not** be forced onto a Comserv-generated
chart. They need:

- **Import** their existing chart of accounts, and their data, into their site's database.
- **Export** back out to their existing package.

This is the interoperability requirement that keeps the system honest: an owner who cannot get their
data out is trapped, and a system that cannot accept an existing chart is unusable by anyone with
history.

> **OPEN — interchange formats not yet verified.** See §7 O2.

---

## 7. Open questions — MUST be answered before code

These are gaps the agent **declined to fill from memory**, because a wrong answer here is exactly
the future legal/compliance problem this design is trying to avoid. Stated by the owner:
*"basing the creation of this system on the current rules makes total sense to avoid coding and
legal issues in the future."*

| # | Question | Status | Blocks |
|---|---|---|---|
| **O1** | GIFI code mapping, `link` semantics, account numbering conventions. | ✅ **CLOSED 2026-08-02** — §4.4, from CRA RC4088(E) Rev.23. Full 764-code list at `root/config/gifi_codes.json`. CRA prescribes **no** chart numbering convention; internal accno is free, `gifi_accno` carries the statutory mapping. `link` is LedgerSMB-internal and read by nothing in `lib/` today. | — |
| **O2** | **Interchange formats.** What QuickBooks, Xero, Sage, Wave and FreshBooks accept for **chart-of-accounts** import/export (CSV layouts, IIF, QBO/QBXML, OFX, QIF) — and which are open vs vendor-proprietary. | ❌ **OPEN — no research performed.** | §6, Ph.5 |
| **O3** | Is GIFI filing in scope today? | ✅ **CLOSED — NO.** GIFI is T2 (corporations) and T5013 (partnerships) only. All owner entities are sole-proprietor DBAs filing **T2125**. `gifi_accno` is therefore forward-looking carve-out infrastructure (§4.4.1), not present compliance — it drops from blocker to seed-it-now. | — |
| **O4** | **Split-off metrics.** What numbers signal an entity should become its own legal entity? | ❌ Open — owner judgement, not research. | §5.3, Ph.4 |
| **O5** | **Overlay numbering.** Fixed bands for teaching / e-commerce accounts, or allocate at merge time? | ⚠️ **Unblocked by O1** — since CRA prescribes no numbering, this is now purely an internal design choice, free to decide. Recommend fixed reserved bands for template stability. Owner decision. | §4.2 |
| **O6** | **T2125 line numbers** for the sole-proprietor / personal archetype — the form actually filed by every current entity. | ❌ **OPEN — NEW.** Not obtained: canada.ca blocks direct fetch from the agent sandbox and T2125 is a PDF. Arguably now the **highest-value** remaining research item, since it governs the form in present use. | §4.1 personal archetype |

### 7.1 Research constraint — local models are not adequate here

A local Ollama model **cannot** be relied on for O1 or O2. Current, jurisdiction-specific accounting
standards and vendor file formats are exactly where a local model will produce confident,
plausible, wrong answers. Owner's assessment, and the agent agrees:

> *"I have my doubts that Ollama model would have current accounting standards that are global —
> this will be an internet connected model that would be needed."*

**Consequence for ACCON Ph.2 (AI chart generation, todo 1804):** the same constraint applies at
runtime, not just to research. This argues for the **archetype templates carrying the
compliance-sensitive structure** (statutory accounts, GIFI codes, tax accounts) while the AI
contributes only the business-model-specific overlay on top. That keeps the compliance surface in
reviewed data rather than in a model's output, and it bounds the cost against the daily API budget.

A first research delegation failed: the configured subagent model (`qwen2.5-coder:14b`, 32K context)
is below the 64K minimum.

**Resolved 2026-08-02** by the agent performing O1/O3 research **in-session via browser** against
the primary source (CRA RC4088) rather than via delegation or model recall. Every figure in §4.4 is
quoted from that document, not recalled. **O1 and O3 are closed. O2 and O6 remain open.**

The delegation-model limit is still unfixed and will block any future research delegation.

---

## 8. Relationship to the other plans

| Plan | Interaction |
|---|---|
| **ACCPG** | Unchanged and reinforced. One PostgreSQL database per SiteName is what makes §0.1's separability requirement achievable. This plan adds the roll-up ACCPG never defined. |
| **ACCON** | §4 **supersedes ACCON §4's flat five-archetype list** with the base + overlay model, and retires "retail / e-commerce" as a base archetype. **§4.4 further requires the apiary archetype be built on the GIFI farm block (9370–9899), not the generic business block** — a correction to any ACCON template work already scoped. ACCON Ph.1 (todo 1803) is the template store this plan's §4 describes. |
| **ACCON Ph.2 (1804)** | Constrained by §7.1 — compliance-sensitive structure belongs in templates, not model output. §4.4 strengthens this: the GIFI mapping is now **reviewed data** in `root/config/gifi_codes.json`, so the AI never needs to produce a statutory code. |

---

## 9. Phases (proposed — not yet decomposed into todos)

| Ph | Deliverable | Gate |
|---|---|---|
| **0** | This plan reviewed and signed off; remaining research (O2, O6) completed with cited sources | owner sign-off; **O1/O3 already closed (§4.4)**; O2 and O6 closed |
| **1** | Owner-draw account structure: §3.2 accounts in the templates, paired-entry recording, both-sides enforcement | a funding payment produces balanced mirror entries in two ledgers; a one-sided entry is refused or flagged |
| **2** | Consolidation read: per-entity summary, combined total, allow-list scoping | report runs across owner entities only; a client site cannot appear in it |
| **3** | Reconciliation check (§5.2) surfaced in the report | a deliberately unbalanced inter-entity pair is detected and reported |
| **4** | Split-off signal metrics (§5.3), once O4 is answered | report shows the trend that informs a carve-out decision |
| **5** | Import / export for external users (§6), once O2 is answered | a chart exported from a mainstream package imports cleanly; a Comserv chart exports back |

---

## 10. What the agent has NOT done

Stated plainly, so review is not misled:

- **No code written** against this plan.
- **Partial research.** O1 and O3 closed from the primary source (CRA RC4088(E) Rev.23), §4.4.
  **O2 (interchange formats) and O6 (T2125 lines) remain entirely open** — no research performed
  on either.
- **Account numbers are now grounded** for GIFI mapping (§3.2, §4.4). The internal `accno` values
  remain the system's own choice — correctly so, since CRA prescribes no numbering convention.
- **No tax position taken** — §3.4, and the §3.2 sole-proprietor GIFI mappings are explicitly
  flagged nearest-match, for accountant review.
- **Entity facts not audited** — §1 records the owner's description; the agent verified none of it.
- **The seed defect in §11 has NOT been fixed** — reported only.

---

## 11. Defect found during research — not fixed, reported only

Found while cross-checking the existing seed against the researched GIFI categories. **Outside this
task's scope; no change made.**

`sql/accounting_template.sql:630`:

```sql
('4260', 'Developer Services — GST/HST Collected', 'A', 'L', 'AR_tax'),
```

The `category` is `L` (liability) — **correct**; GST/HST collected is money held for the Crown, not
revenue. But the account is numbered **4260, inside the 4000 revenue band**, alongside `4250
Developer / IT Services Revenue`.

**Impact.** Any statement or report that groups by account-number band — as most chart-ordered
reports do — will present a tax liability under Revenue, overstating income by the GST/HST collected.
Reports grouping strictly by `category` are unaffected.

**Suggested fix.** Renumber into the 2100s beside the existing GST/HST payable accounts (`2100
GST/HST Payable`, `2110 PST Payable`).

**Why it was not fixed here.** It is a seed change affecting any accounting database **already
provisioned** from this template — those databases will keep the old number until migrated. That
makes it a schema-versioned migration (ACCPG `SCHEMA_VERSION`), not a one-line edit, and it needs
its own todo and owner decision.
