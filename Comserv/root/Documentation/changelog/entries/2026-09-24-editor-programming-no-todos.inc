<div id="2026-09-24-editor-programming-no-todos" class="cl-entry">
<h3>2026-09-24 — AI Editor programming phase does not create todos</h3>
<p class="doc-body"><strong>What.</strong> <code>/ai2/chat</code> with editor agent_id (programming/coding/code/documentation/analyze) or editor phase no longer runs TodoCreate / HelpDesk / Invoice / Scheduler intercepts, and no longer injects those ACTION contracts. Plan contract no longer says to update todos.</p>
<p class="doc-body"><strong>Why.</strong> The editor posts the open buffer plus a phase contract that mentions todos; intercepts treated that as a real create (#2423).</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/AI2.pm</code> <code>lib/Comserv/Model/AI2/{Chat,ChatIntent}.pm</code> <code>root/static/js/ai2editor/chat.js</code></p>
</div>
