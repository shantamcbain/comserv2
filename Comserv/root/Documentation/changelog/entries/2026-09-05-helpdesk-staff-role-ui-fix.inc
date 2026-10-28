<div id="2026-09-05-helpdesk-staff-role-ui-fix" class="cl-entry">
<h3>2026-09-05 — Fix HelpDesk staff UI for 'helpdesk' role + template parse error</h3>
<p class="doc-body"><strong>What.</strong> Fixed TT parse error (stray ELSE/END) in new_ticket.tt and contact.tt. Updated HelpDesk index to stash is_staff, main landing to show staff tools card for helpdesk role (Open Queue, All Tickets). Added /HelpDesk/queue and /HelpDesk/staff actions. ticket_list now uses staff title when applicable. Greeting falls back to username.</p>
<p class="doc-body"><strong>Why.</strong> helpdesksupport bot had role but saw only member UI; /ticket/new 500 blocked all; queue/staff paths didn't provide staff views; greeting blank.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/HelpDesk.pm</code>, <code>Comserv/root/CSC/HelpDesk.tt</code>, <code>Comserv/root/CSC/HelpDesk/new_ticket.tt</code>, <code>Comserv/root/CSC/HelpDesk/contact.tt</code></p>
</div>