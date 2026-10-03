<div id="2026-09-28-fallback-hops-past-same-pool" class="cl-entry">
<h3>2026-09-28 — Chat fallback walks other free families, then Ollama</h3>
<p class="doc-body"><strong>What.</strong> A 429 on <code>google/gemma-4-26b-a4b-it:free</code> only tried the other Gemma <code>:free</code> model (same Google rate-limit pool) and never Ollama. The failed hop was logged as <code>error</code>, which filed an audit todo even though failover was supposed to continue.</p>
<p class="doc-body"><strong>Why.</strong> <code>pick_free_fallback</code> returned only the first other <code>:free</code> slug, and its catalog call omitted Ollama (<code>include_ollama</code> defaults off). Both Gemma models 429 together, so the turn died.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Router.pm</code>, <code>t/model_ai2_router_outage.t</code></p>
</div>
