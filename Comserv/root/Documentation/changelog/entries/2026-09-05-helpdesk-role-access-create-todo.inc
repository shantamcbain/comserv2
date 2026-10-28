<div id="2026-09-05-helpdesk-role-access-create-todo" class="cl-entry">
<h3>2026-09-05 — Add helpdesk role and grant access for HelpDesk todo creation</h3>
<p class="doc-body"><strong>What.</strong> Added 'helpdesk' to default and available roles lists in user management, pages, and documentation. Updated HelpDesk nav to show admin resources for helpdesk role. Existing _is_staff and create_todo/escalate already support 'helpdesk' role.</p>
<p class="doc-body"><strong>Why.</strong> To allow users with helpdesk role full access to the HelpDesk system (including staff create_todo and escalate_ticket features for supporting tickets).</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/User.pm</code>, <code>Comserv/lib/Comserv/Controller/Pages.pm</code>, <code>Comserv/lib/Comserv/Controller/Documentation.pm</code>, <code>Comserv/root/Navigation/TopDropListHelpDesk.tt</code></p>
</div>