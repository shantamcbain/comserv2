<div id="2026-08-29-todo-create-subject-max" class="cl-entry">
<h3>2026-08-29 — TodoCreate clamps subject to 255 chars</h3>
<p class="doc-body"><strong>What.</strong> AI chat todo create no longer fails with <code>Data too long for column 'subject'</code> when the model dumps a long request into subject. Overflow is moved into <code>description</code>.</p>
<p class="doc-body"><strong>Why.</strong> Application Error Audit #2344 from <code>Model::AI2::TodoCreate</code> insert path.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/TodoCreate.pm</code>, <code>t/model_ai2_todo_create.t</code></p>
</div>
