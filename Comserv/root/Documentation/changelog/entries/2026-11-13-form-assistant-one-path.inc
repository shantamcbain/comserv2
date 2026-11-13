<div id="2026-11-13-form-assistant-one-path" class="cl-entry">
<h3>2026-11-13 — Add and edit forms use one AI path</h3>
<p class="doc-body"><strong>What.</strong> The shared AI Form Assistant no longer keeps its own model list or calls <code>/ai/generate</code>. Ask and Review post to <code>/ai2/chat</code> and use the Chat with AI model selector. Encyclopedia and Health Kitchen pages use the ency agent. Todo, planning, bee, and helpdesk pages use their own agent. Other forms use general. Health Kitchen history and the new-symptom form now include the assistant.</p>
<p class="doc-body"><strong>Why.</strong> Add and edit forms had a second AI client. The encyclopedia record forms already shared one panel. The rest of the add and edit forms needed the same entry, with the agent that matches the page.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/ai/partials/ai_form_assistant.tt</code>, <code>Comserv/root/healthkitchen/history.tt</code>, <code>Comserv/root/healthkitchen/symptoms.tt</code></p>
</div>
