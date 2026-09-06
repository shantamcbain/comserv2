<div id="2026-09-05-helpdesk-bot-staff-role-fix" class="cl-entry">
<h3>2026-09-05 — Auto-promote helpdesksupport bot to helpdesk staff role</h3>
<p class="doc-body"><strong>What.</strong> Added auto-assignment of 'helpdesk' role on login for username 'helpdesksupport' or email 'helpdesk@computersystemconsulting.ca'. Persists to user.roles and sets in session.</p>
<p class="doc-body"><strong>Why.</strong> The helpdesk bot account was stuck with 'normal' role, limiting it to member controls (own tickets only) instead of staff queue/assign/create_todo/escalate in HelpDesk.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/User.pm</code></p>
</div>