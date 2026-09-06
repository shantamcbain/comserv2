<div id="2026-09-05-helpdesk-todo-create-fix" class="cl-entry">
<h3>2026-09-05 — Fix HelpDesk create_todo / escalate_ticket</h3>
<p class="doc-body"><strong>What.</strong> Fixed crashes when creating todos from HelpDesk tickets: "project_code" method not found on SupportTicket, then DB "Field 'parent_todo' doesn't have a default value" (and other NOT NULL columns like due_date, project_id, last_mod_by etc.).</p>
<p class="doc-body"><strong>Why.</strong> The recently added staff actions did a direct $ticket->project_code (column does not exist on SupportTicket) and a minimal Todo->create() that omitted required fields. start_date used DBIC hash literal that became a ref in the bind.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/HelpDesk.pm</code></p>
</div>