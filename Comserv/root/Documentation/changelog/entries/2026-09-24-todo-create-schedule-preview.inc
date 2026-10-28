<div id="2026-09-24-todo-create-schedule-preview" class="cl-entry">
<h3>2026-09-24 — Todo create previews queue-aware start (#2218)</h3>
<p class="doc-body"><strong>What.</strong> After Chat-with-AI writes a todo, <code>TodoCreate</code> now asks <code>AI2::Scheduler</code> for a queue-tail date and appends an advisory line. Nothing is written until the user says apply schedule for that one id.</p>
<p class="doc-body"><strong>Why.</strong> New todos were stamped <code>start_date=today</code> and buried the queue. Focus Queue still uses <code>scheduled_date=today</code>. Advisory only; no bulk rewrite.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/TodoCreate.pm</code></p>
</div>
