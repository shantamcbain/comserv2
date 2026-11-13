<div id="2026-11-13-ency-ai-one-path" class="cl-entry">
<h3>2026-11-13 — ENCY Ask AI uses Chat with AI and the ency agent</h3>
<p class="doc-body"><strong>What.</strong> Add Herb and the other ENCY forms that include AiFormFill no longer keep a private Grok model list or call <code>/ai/generate</code>. Ask and Review post to <code>/ai2/chat</code> with <code>agent_id: ency</code>. The model is the Chat with AI selector; an empty selection is the server Router.</p>
<p class="doc-body"><strong>Why.</strong> The panel was a second AI client. It listed only Grok and fell back to the dead model <code>grok-beta</code>, so Ask AI failed while Chat with AI on the same page worked. Ency and HealthKitchen now use the encyclopedia agent, whose text is accurate herbal, plant, and animal records and a refusal to invent a species, dose, constituent, or citation.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/ENCY/partials/AiFormFill.tt</code>, <code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code></p>
</div>
