<div id="2026-11-19-inv-r1-recurring-supplier-invoice" class="cl-entry">
<h3>2026-11-19 — Recurring supplier subscriptions + payment source (INV-R1 #2190)</h3>
<p class="doc-body"><strong>What.</strong> Monthly vendor charges (memberships, support plans, SaaS) can now be
recorded once as a <strong>schedule</strong> instead of being re-keyed every month. Two new tables hold the
plan: <code>inventory_recurring_invoices</code> (supplier, cadence, next generate date, optional end date,
payment source, AP account, default expense account, auto-pay flag) and
<code>inventory_recurring_invoice_lines</code> (the line templates cloned onto each generated invoice).
New page <a href="/Accounting/recurring" style="color:var(--link-color)">/Accounting/recurring</a> lists
the schedules and carries a <strong>Run Due</strong> button.</p>
<p class="doc-body"><strong>Why.</strong> Supplier subscriptions were being hand-entered as invoices, so a
missed month silently understated AP and expense. Schedule rows are cloned into real
<strong>draft</strong> rows on <code>inventory_supplier_invoices</code> by
<code>Util::Accounting::RecurringInvoice</code> once <code>recurrence_next_date</code> arrives, then the
schedule advances. Generation is idempotent per period (re-running Run Due on the same day does not
create a second invoice) and month/year stepping is calendar-correct — a 31st-of-month schedule clamps
to the last day of short months and back, so it never drifts to the 28th or skips February. The
generated invoice stays a <strong>draft</strong> so the posting and its GL entry remain a human review
step, matching the existing chat/draft invoice path. Payment source is
<code>payment_account_id</code> → <code>coa_accounts</code> — a real bank/credit-card asset account the
charge is paid <em>from</em>, not free text — so AP reporting can show where money actually leaves.
Unblocks <strong>DRYER-INT #2250</strong> (CC3D/HDRY membership + invoice) and closes todo
<strong>#2190</strong>.</p>
<p class="doc-body"><strong>Hardening (review rounds).</strong> The page and every action on it are
administrator-only — the earlier local-IP bypass and hardcoded admin username are gone, and a POST is
refused unless it is same-origin (<code>Comserv::Util::OriginCheck</code>). The site is taken from the
session, never from a <code>sitename</code> parameter or <code>X-Sitename</code> header, so a schedule
cannot read or bill another site. Every id from the form is re-checked against the site (supplier and
all accounts, including the payment source, which must be an asset account), money fields must be
numeric, and dates are validated as real calendar dates so an impossible date is rejected at save time
instead of failing at generation. Editing a schedule keeps its item/location line links and its
tax/shipping amounts, and <code>run_due</code> re-reads each schedule under a row lock so the button and
the cron script cannot both bill the same period.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryRecurringInvoice.pm</code>,
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryRecurringInvoiceLine.pm</code>,
<code>Comserv/lib/Comserv/Util/Accounting/RecurringInvoice.pm</code>,
<code>Comserv/lib/Comserv/Controller/Accounting/Recurring.pm</code>,
<code>Comserv/root/Accounting/recurring/index.tt</code>,
<code>Comserv/script/generate_recurring_invoices.pl</code>,
<code>Comserv/root/Documentation/Accounting/invoices.tt</code></p>
</div>
