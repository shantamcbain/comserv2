<div id="2026-10-27-planning-attention-section-filtering-issue" class="cl-entry">
<h3>2026-10-27 — Planning Attention Section Todo Filtering Issue</h3>
<p class="doc-body"><strong>What.</strong> The planning attention section is not properly filtering todos to show only overdue items or branch-specific todos. The AttentionOrder module correctly identifies branches and projects needing attention, but the todo filtering system appears to be showing all todos rather than applying proper filters.</p>
<p class="doc-body"><strong>Why.</strong> Investigation needed to determine why the todo filtering is not working as expected. The Todo controller has filtering logic for overdue items and date ranges, but it may not be properly integrated with the planning attention section.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Planning.pm</code>, <code>lib/Comserv/Controller/Todo.pm</code>, <code>lib/Comserv/Util/AttentionOrder.pm</code>.</p>
</div>