<div id="2026-09-24-openrouter-503-task-assistant" class="cl-entry">
<h3>2026-09-24 — OpenRouter 503 fallback keeps Task Assistant prompt</h3>
<p class="doc-body"><strong>What.</strong> Fallback hops after a 502/503/504 now receive the same <code>%opts</code> and the original <code>$messages</code> (system prompt + ACTION contract). Task Assistant (<code>agent_id=todo</code>) is told never to claim it has no todo tool after a retry. Public errors still hide raw 503.</p>
<p class="doc-body"><strong>Why.</strong> #2292/#2293 already retried; #2294 a 503 hop-down was answering without the todo contract.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Router.pm</code> <code>lib/Comserv/Model/AI2/Chat.pm</code> <code>t/model_ai2_router_outage.t</code></p>
</div>
