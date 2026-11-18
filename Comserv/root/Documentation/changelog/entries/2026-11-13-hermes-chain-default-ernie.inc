<div id="2026-11-13-hermes-chain-default-ernie" class="cl-entry">
<h3>2026-11-13 — Perl Hermes chain default matches the live file</h3>
<p class="doc-body"><strong>What.</strong> <code>@HERMES_CHAIN_DEFAULT</code> now follows the live <code>hermes_fallback_chain</code>: Super Grok, particle-1, luna, ernie free, north-mini last. The paid <code>xai|grok-4.7</code> step is not in the Perl fallback.</p>
<p class="doc-body"><strong>Why.</strong> When <code>data/ai_model_chains.json</code> is not used, the guard falls back to the Perl list. That list still had <code>xai|grok-4.7</code> after the live file had removed it (x.ai direct cap is 0) and had put ernie ahead of north-mini.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/AI/ModelChains.pm</code>.</p>
</div>
