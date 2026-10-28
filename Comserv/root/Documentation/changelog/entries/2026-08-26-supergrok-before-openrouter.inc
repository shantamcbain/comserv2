<div id="2026-08-26-supergrok-before-openrouter" class="cl-entry">
<h3>2026-08-26 — SuperGrok first; never OpenRouter Grok; fail to :free / Ollama</h3>
<p class="doc-body"><strong>What.</strong> Grok-named models (<code>grok-*</code>, <code>x-ai/grok-*</code>, <code>openrouter|x-ai/grok-*</code>) now route to SuperGrok (prepaid weekly credits). They are not sent to OpenRouter (that bills OpenRouter). App default is SuperGrok <code>grok-4.6</code> when the OAuth token is present, not paid OpenRouter. SuperGrok failure still falls back to a cheaper OpenRouter <code>:free</code> model then Ollama. Free fallback never picks a Grok slug.</p>
<p class="doc-body"><strong>Why.</strong> Weekly SuperGrok credits must be used before paying OpenRouter. OpenRouter Grok and xAI pay-per-token Grok are not the SuperGrok hop.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AI2/Router.pm</code> <code>Comserv/t/model_ai2_router_outage.t</code></p>
</div>
