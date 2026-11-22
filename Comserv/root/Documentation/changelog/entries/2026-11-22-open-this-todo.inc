<div id="2026-11-22-open-this-todo" class="cl-entry">
<h3>2026-11-22 — "Open this todo" opens the todo instead of asking for a new subject</h3>
<p class="doc-body"><strong>What.</strong> In Chat-with-AI, "open this todo", "open todo #123", and similar phrases now open that todo (from the number in the message, or the todo page you are already on). If no number is available, the assistant asks for the todo number. It no longer starts the create-todo subject prompt.</p>
<p class="doc-body"><strong>Why.</strong> HelpDesk CSC-20260914-9320. "Open this todo" was being treated as a request to create a todo, so the chat asked for a subject instead of opening the current item.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/ChatIntent.pm</code>, <code>lib/Comserv/Model/AI2/TodoCreate.pm</code>, <code>t/model_ai2_todo_create.t</code></p>
</div>
