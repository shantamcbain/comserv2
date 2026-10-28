<div id="2026-09-30-ollama-upgrade" class="cl-entry">
<h3>2026-09-30 — Upgrade Ollama to 0.35+</h3>
<p class="doc-body"><strong>What.</strong> Upgraded Ollama to version 0.35.0 and pulled decision models nimble, tev1, and tev1:0.8b for local System One API usage.</p>
<p class="doc-body"><strong>Why.</strong> Ollama 0.35+ adds the System One API (POST /v1/systemone) for structured decision outputs with probabilities/confidence, enabling local triage/routing/classification without expensive model hops.</p>
<p class="doc-body"><strong>Files.</strong> <code>script/sync_ollama_models.sh</code> — added nimble:latest, tev1:latest, tev1:0.8b to RECOMMENDED list; <code>root/Documentation/AISYSTEMPlan.tt</code> documents the local decision models wave.</p>
</div>