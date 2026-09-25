<div id="2026-09-25-todo-work-status-check" class="cl-entry">
<h3>2026-09-25 — Todo Start checks status 5 instead of toggle-stopping</h3>
<p class="doc-body"><strong>What.</strong> Being-worked is todo status 5 (open log). <code>TodoLog::work_status</code> reports one todo or every active session. Start (<code>open_log</code>) on an already-active todo returns <code>already_active</code> and does <strong>not</strong> close the log — so a stale ▶ Start click or a second API open cannot kill a running session. New <code>GET /api/todo/work_status</code> (optional <code>?record_id=</code>) is the AI/staff report. Done on an already-done todo returns <code>already_done</code> without inserting a second completed log.</p>
<p class="doc-body"><strong>Why.</strong> Agents never queried who was working; Start was a toggle, so a leftover status-5 log (or a stale daily-plan page) got stopped instead of reported.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/TodoLog.pm</code>, <code>Comserv/lib/Comserv/Controller/Api.pm</code>, <code>Comserv/lib/Comserv/Controller/Todo.pm</code>, <code>Comserv/root/static/js/planning/daily-plan-utils.js</code></p>
</div>
