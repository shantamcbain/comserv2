<div id="2026-11-22-chat-todo-create-action" class="cl-entry">
<h3>2026-11-22 — Chat-with-AI "add a todo" goes through one create brain</h3>
<p class="doc-body"><strong>What.</strong> "Add a todo…" in Chat-with-AI already had a server intercept and an ACTION contract for logged-in, non-editor agents. The leftover <code>/ai/action create_todo</code> path now uses the same <code>AI2::TodoCreate</code> brain as <code>/ai2/action</code>, so it matches SiteName/project instead of inserting a loosely-filed row. A regression test covers the contract, the editor skip, the intercept, and <code>perform_create</code> (the /ai2/action entry).</p>
<p class="doc-body"><strong>Why.</strong> Todo #2295. The model used to claim it had no todo-creation tool. The Chat-with-AI path was wired in September but never proven end-to-end, and the old /ai/action insert could skip the shared project matcher.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/AI.pm</code>, <code>t/model_ai2_todo_create_action.t</code></p>
</div>
