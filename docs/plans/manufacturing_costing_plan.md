# Manufacturing costing plan (3D first, generic later)

Branch `3d`, written 2026-10-17. Plan only; no code or DB changes yet.

## What exists today (survey)

| Area | What is there | Gap |
|---|---|---|
| Inventory item | `inventory_items`: `unit_cost`, `unit_price`, `selling_price`, `discount_percent`, `print_time_hours`, `requires_printing`, `is_assemblable`, `item_origin` | No markup setting, no labour/time settings, no "cost last calculated" record |
| Recipe / BOM | `inventory_item_bom` (parent, component, qty, unit `g`, `scrap_factor`) | Material only; no process steps or labour |
| Machine | `inventory_equipment`: `wattage`, `depreciation_per_hour`, linked from `printing_3d_printers.inventory_item_id` | OK for wear & tear + power; kWh rate hard-coded at $0.15 in `Controller/3d.pm` |
| Print job | `printing_3d_jobs`: `filament_quantity`, `print_hours`, `filament_cost`, `printer_cost`, `electricity_cost`, `total_cost` | No labour cost, no link to an order/invoice/customer, no payment status |
| Complete action | `Controller/3d.pm` queue complete: cost = grams × spool $/g + hours × depreciation + hours × W × 0.15/1000; issues filament stock | Does **not** touch the produced item's `unit_cost` or `selling_price`; no labour |
| Labour | `/3d/labour/log` (`Printing3dLabour.pm`) → `Traveler::record_clean_labour`: minutes × rate (`point_rules` hourly_rate, default 60/hr) **added onto `inventory_items.unit_cost`** each time; time kept only as text in notes/admin_notes | Unit cost grows with every log (not per unit); no structured labour rows; only "clean" category really used |
| Upload | `/3d/print_upload`: login required, estimates grams from STL ("not a sliced quote") | No price, no payment step, no member/new-customer check |
| Checkout | `Cart.pm` creates `inventory_customer_invoices` (cash/points per site policy); `payment_transactions` table exists | Print jobs never go through the cart |

---

## Phase 1: Complete → cost rollup into the item + selling price (BUILT on `3d`)

**Problem.** Marking a print Complete stored costs on the job only; the produced item kept an old/manual cost and price, labour was missing (or wrongly added to `unit_cost` on every log), and there was no markup rule.

**Evidence.** The complete action in `Controller/3d.pm` updated only `printing_3d_jobs`; `Traveler::record_clean_labour` did `unit_cost = old + labour`; electricity used a hard-coded $0.15/kWh.

**Impact.** Shop and invoice prices were guesses; repeated labour logs inflated item cost.

**Solution (as built).**
- `Comserv::Util::Manufacturing::Costing` (generic). Run cost = filament (actual g × $/g) + machine wear (h × depreciation/h) + electricity (h × W × kWh rate) + labour (minutes per step × labour rate), then a normal scrap allowance (yield method: total ÷ (1 − scrap%)), ÷ units made.
- On Complete (before the finished goods are received) the item's `unit_cost` becomes a weighted moving average of stock on hand and the new run; `selling_price = unit_cost × (1 + markup%)` rounded **up** to $0.05 CAD, unless `manual_price = 1`. Each change is written to `mfg_cost_history`; the breakdown JSON is stored on the job.
- Traveler labour no longer adds to `unit_cost`. Logged minutes replace that job's default minutes for the step (once); extra labour without a default is spread over stock on hand.
- Settings in `comserv.conf` `<Manufacturing>` (editable): currency CAD, markup 50%, labour $38.46/h, kWh $0.1408, scrap 5%, round to 0.05, default minutes: queue 2, slicing 5 (skipped for pre-sliced gcode/gcode.3mf), send 2, filament change 3 each, maintenance share 3, collect & clean 5.
- Degrades safely: missing columns/table are skipped with a warning.

**Cost method (why).** Manufacturers either use a standard cost (fixed, with variances booked separately) or a moving average (re-averaged on every receipt). For a small shop with no cost accountant, a moving average is simpler and does what Shanta asked: a failed reprint, a filament price spike or a cheap spool on sale raises or lowers the average a little instead of landing on one print. Normal, expected failures are built in as a scrap/yield allowance (accounting standards include normal scrap in inventory cost and expense abnormal waste), so good parts carry the cost of the usual failures; an unusual failure can be left out of the average by staff.

**Researched defaults (CAD).**
- Markup 50%: small/local 3D print services price at roughly 30–60% over full cost (filamentfeed.com "30–50%"; 3droy.com "local consumer service 40–60%").
- Labour $38.46/h: BC median wage, manufacturing technician (Government of Canada Job Bank, Nov 2025). The markup covers overhead and profit, so labour is charged at the wage. Print-farm operator pay in Canada is $18–30/h (3dcentral.ca) if Shanta wants a lower rate.
- Electricity $0.1408/kWh: BC Hydro residential tiered rate, Tier 1 11.87¢ / Tier 2 14.08¢ (since July 1 2026). Tier 2 is used because the printer's kWh are on top of household use, so they are billed at the marginal (Tier 2) price.
- Default minutes: ~12–17 hands-on minutes per job, in line with the "about 30 minutes of hands-on labour" per job that pricing guides assume including post-processing; tune in config as traveler logs build up.

**Risk / undo.** Prices change automatically on Complete. Set `manual_price = 1` on an item to freeze its price; `mfg_cost_history` keeps old → new cost and price for manual revert; removing the `rollup_job` call (one block in `Controller/3d.pm`) turns it off.

## Phase 2: Structured labour and traveler time

**Problem.** Labour time is free text in notes; only some steps can be logged.

**Evidence.** `admin_notes` / item `notes` lines written by `record_clean_labour`; traveler pages don't save step times.

**Impact.** Actual labour can't be summed per job; estimates never improve.

**Solution.** `mfg_labour_log` rows (job, step, minutes, user, source = timer|manual|default). Timer buttons for each step on the queue/traveler; filament change counted from the job's filament changes. Optional: update an item's default minutes from the average of recent actuals.

**Risk / undo.** Extra clicks for staff; defaults still apply when nothing is logged. Table is additive; dropping it reverts to defaults.

## Phase 3: Ordering, accounts and prepayment

**Problem.** Anyone logged in can queue a print; nobody pays before the printer starts; uploads have no price.

**Evidence.** `PrintUpload.pm` only checks `session->{user_id}`; jobs have no payment or order link.

**Impact.** Unpaid work, and no invoice for prints.

**Solution.**
- Non-members: must create an account (already enforced by login) — add a clear "create account to print" path.
- Catalogue items (known cost): price = item `selling_price`; pay through the existing Cart before the job is queued.
- Uploads (unknown cost): estimate from STL grams + default hours/labour + markup; take a deposit (rule below) through the Cart; job status `awaiting_payment` until paid. After Complete, the rollup gives the true price; create the final invoice for the difference (or credit if lower).
- Existing customers: rule choice (pay-first for everyone, or trusted customers billed after).

**Risk / undo.** Blocks walk-in/manual prints; staff/admin override "queue without payment" with a logged reason.

## Phase 4: Generic for other processes

**Problem.** Costing is tied to 3D tables.

**Solution.** Process definitions (`mfg_process`: 3D print, laser, assembly, …) with their own step list and machine; `Costing` takes a process + run record. 3D becomes the first process.

**Risk / undo.** Refactor only after Phases 1–3 are stable.

---

## Schema changes (minimal) — `sql/20261017_manufacturing_costing.sql`

Phase 1 (4 columns + 1 table):
- `inventory_items.markup_percent DECIMAL(6,2) NULL` (NULL = site default)
- `inventory_items.manual_price TINYINT(1) NOT NULL DEFAULT 0`
- `printing_3d_jobs.labour_cost DECIMAL(10,4) NULL`
- `printing_3d_jobs.cost_breakdown TEXT NULL` (JSON: step minutes, components, scrap, unit cost, actual logged steps)
- New `mfg_cost_history` (item, job, event, old/new cost, old/new price, detail JSON, who, when). Result class: `MfgCostHistory`.
- Settings stay in `comserv.conf` `<Manufacturing>` (no settings table).
- The 4 columns are NOT added to the `InventoryItem` / `Printing3dJob` Result classes yet, because an unapplied column in a Result class breaks every query on that table. Add them to the Result classes after the SQL is applied.

Phase 2: per-step labour stays in `cost_breakdown.actual` (no new table unless reporting needs it).

Phase 3: `printing_3d_jobs.invoice_id INT NULL`, `payment_status VARCHAR(20) NULL` (estimate/deposit amounts kept in `cost_breakdown`).

## Decisions for Shanta

Phase 1 decided (Oct 17): industry markup (50%), BC labour rate ($38.46/h), CAD, moving average + scrap allowance, BC Hydro Tier 2 kWh, round up to $0.05.
Still open: deposit rule for uploads (% of estimate / minimum / full) and refund vs credit on true-up; pay-first for existing customers or invoice trusted ones after.
