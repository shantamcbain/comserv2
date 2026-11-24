<div id="2026-11-24-git-suggest-skip-drain" class="cl-entry">
<h3>2026-11-24 — Git suggest reached a model after a replace-verdict skip</h3>
<p class="doc-body"><strong>What.</strong> Suggest message with AI on the Git dashboard returned “No AI model is available right now (all options failed or are over budget)” without calling any model. The pinned free model was skipped for an effectiveness replace verdict, and the remaining chain step was an empty placeholder.</p>
<p class="doc-body"><strong>Why.</strong> The last-resort tail (Super Grok, then local Ollama) ran only after a failed HTTP attempt. A skip-only drain never started it. The suggest call also used the chat chain and spent about 5s on a classifier that could not change an explicit model pick.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Router.pm</code>, <code>lib/Comserv/Controller/Admin/Git.pm</code>, <code>t/ai_model_failover.t</code>.</p>
</div>
