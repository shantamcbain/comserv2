<div id="2026-08-31-helpdesk-daily-ticket-links" class="cl-entry">
<h3>2026-08-31 — Daily Plan HelpDesk links open the ticket, not public index</h3>
<p class="doc-body"><strong>What.</strong> Open-ticket rows on <code>/planning/daily</code> and Start Day HelpDesk notices now link to <code>/HelpDesk/ticket/view/&lt;ticket_number&gt;</code> (and the open-tickets admin list). Previously they used <code>/HelpDesk/ticket/&lt;number&gt;</code> or bare <code>/HelpDesk</code>, which hit the HelpDesk default action and showed the public HelpDesk page.</p>
<p class="doc-body"><strong>Why.</strong> Staff clicked a daily notification expecting the ticket thread and landed on the public landing page instead.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/admin/planning/_today_work_tab.tt</code>, <code>Comserv/lib/Comserv/Controller/Planning.pm</code></p>
</div>
