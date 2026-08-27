<div id="2026-08-26-llama3-ollama-not-openrouter" class="cl-entry">
<h3>2026-08-26 — local llama3.* tags stay on Ollama</h3>
<p class="doc-body"><strong>What.</strong> <code>/api/focus/top5</code> sent <code>llama3.1:8b</code> to OpenRouter, which returned 400 "is not a valid model ID" (audit todo 2308).</p>
<p class="doc-body"><strong>Why.</strong> <code>Router::_detect_provider</code> treated anything matching <code>/^(llama3|...)/i</code> as external. Ollama tags are <code>name:tag</code>; OpenRouter ids are <code>org/model</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Router.pm</code>, <code>t/provider_grok_supergrok.t</code>.</p>
</div>
