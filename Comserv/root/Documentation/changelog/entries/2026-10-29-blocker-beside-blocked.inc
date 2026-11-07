<div id="2026-10-29-blocker-beside-blocked" class="cl-entry">
<h3>2026-10-29 — Blocker sits beside the todo it blocks</h3>
<p class="doc-body"><strong>What.</strong> The focus queue no longer floats every <code>is_blocking</code> row to the top. A blocker is listed only in a list that already contains a todo it blocks, and it sits immediately before that row. A started todo (status 5) stays on the list even when the todos it blocks are not in this branch.</p>
<p class="doc-body"><strong>Why.</strong> #2280 is a schema pointer filed on project 138. It was showing first on the planning list because the sort treated <code>is_blocking</code> as membership. It blocks #2282 and #2283, which are accounting work. Those belong on the accounting list and on main. Once started, #2280 must still show so it is not started again.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/FocusRanking.pm</code>, <code>lib/Comserv/Controller/Planning.pm</code>, <code>t/util_todo_ranking.t</code></p>
</div>
