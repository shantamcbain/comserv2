<div id="2026-08-26-openrouter-503-retry" class="cl-entry">
<h3>2026-08-26 — OpenRouter 503 retries then falls back; users never see raw provider errors</h3>
<p class="doc-body"><strong>What.</strong> A 502/503/504 from OpenRouter (or “Service Unavailable”) now retries the same model twice with 1s/2s backoff, then treats the hop as down so the existing :free → Ollama chain runs. The chat widget shows a short “model temporarily unavailable” line; the raw 503 stays in the server log.</p>
<p class="doc-body"><strong>Why.</strong> A single OpenRouter 503 used to kill the turn. The model then answered without the ACTION/todo contract. Fallback already existed for 402/429/connect failures but not 503.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AI2/Router.pm</code> <code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code> <code>Comserv/t/model_ai2_router_outage.t</code></p>
</div>
