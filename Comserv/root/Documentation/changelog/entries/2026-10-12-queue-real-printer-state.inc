<div id="2026-10-12-queue-real-printer-state" class="cl-entry">
<h3>2026-10-12 — Print queue shows the printer's REAL state, not the assign-click status</h3>
<p class="doc-body"><strong>What.</strong> /3d/queue now passes the live LAN snapshot it already
fetches (per-printer fetch_state: busy/free, filename, progress %, temps) to the template.
A new <strong>Printers — Live State</strong> section lists every farm printer — assigned or
not — with its real state (● printing + file/progress, ● idle, ● offline — unreachable,
● no LAN link) and a ▶ Start Print button when the printer is really idle. The Active table's
Printer cell shows the same badge, and the ▶ Start Print button appears there when the
assigned printer is idle (opens the Files-on-Printer popup with use-existing / send-new choices).
The assign dropdown no longer trusts the DB status: a DB-idle printer whose live state is
busy is excluded ("Not offered (really busy)" note), and unreachable printers stay offered
but marked "offline — unverified" / "state unverified".</p>
<p class="doc-body"><strong>Why.</strong> The DB status flips on assign/complete/cancel clicks
only, so the queue could show a printer as available (or printing) while the physical printer
was in the opposite state. The user: "the queue needs to know the real state of the printer,
not just because the assign was clicked."</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/3d.pm</code> (queue:
%real_state captured, assignable/unavailable classification, farm_printers stash),
<code>root/3d/queue.tt</code> (live-state badges, Start Print buttons, filtered dropdown,
Printers — Live State section).</p>
</div>
