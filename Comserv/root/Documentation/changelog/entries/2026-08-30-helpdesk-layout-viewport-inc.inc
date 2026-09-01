<div id="2026-08-30-helpdesk-layout-viewport-inc" class="cl-entry">
<h3>2026-08-30 — HelpDesk page layout & viewport fix</h3>
<p class="doc-body"><strong>What.</strong> HelpDesK pages had no <code><meta name="viewport" content="width=device-width, initial-scale=1"></code>, so browsers rendered at fixed desktop width (≈980px). On single-monitor setups the <code>helpdesk-container max-width</code> caused horizontal scrolling — users never saw the full page and there was no bottom scrollbar/slider. In addition, the "Back to Tickets" link was buried at the page bottom after replying, requiring extra scrolling.</p>
<p class="doc-body"><strong>Why.</strong> The .tt page headers only had a debug-mode echo block; the viewport meta tag was never added. The reply box "Back to Tickets" link only appeared in the admin navigation, not in the staff/customer reply area.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/root/CSC/HelpDesk/ticket_view.tt</code>,
<code>Comserv/root/CSC/HelpDesk/ticket_status.tt</code>,
<code>Comserv/root/CSC/HelpDesk/admin_tickets.tt</code>,
<code>Comserv/root/CSC/HelpDesk/contact.tt</code>,
<code>Comserv/root/CSC/HelpDesk/new_ticket.tt</code>,
<code>Comserv/root/CSC/HelpDesk/admin.tt</code>,
<code>Comserv/root/CSC/HelpDesk/kb.tt</code>,
<code>Comserv/root/CSC/HelpDesk/ticket_submitted.tt</code>,
<code>Comserv/root/CSC/HelpDesk/linux_commands.tt</code></p>
</div>