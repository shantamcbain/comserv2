<div id="helpdesk-todo-escalation" class="cl-entry">
<h3>2026-09-01 — HelpDesk Todo Creation and Escalation</h3>
<p class="doc-body"><strong>What.</strong> Added two new admin actions on the HelpDesk ticket view: <code>create_todo</code> to track time worked on a ticket, and <code>escalate_ticket</code> to create a high-priority escalation todo.</p>
<p class="doc-body"><strong>Why.</strong> Admins needed a way to track time spent working on tickets and to flag tickets for escalation, both of which were previously unavailable in the HelpDesk admin interface.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/HelpDesk.pm</code> - added <code>create_todo</code> and <code>escalate_ticket</code> actions; <code>Comserv/root/CSC/HelpDesk/ticket_view.tt</code> - added Work On and Escalate buttons</p>
</div>