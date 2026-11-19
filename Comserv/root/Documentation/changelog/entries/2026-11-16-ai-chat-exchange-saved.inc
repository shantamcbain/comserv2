<div id="2026-11-16-ai-chat-exchange-saved" class="cl-entry">
<h3>2026-11-16 — AI chat saves the prompt and the reply on every exchange</h3>
<p class="doc-body"><strong>What.</strong> An editor turn that GitFix (or any other early return) answered never wrote <code>ai_messages</code>. The prompt and the reply now save on every <code>/ai2/chat</code> exchange, including those intercepts. The typed ask is the message; the full posted prompt is in metadata.</p>
<p class="doc-body"><strong>Why.</strong> The 16:36 editor chat could not be read back. GitFix returned before <code>Chat.pm</code> persist, so the question and the fiction reply were gone.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Chat.pm</code>, <code>lib/Comserv/Controller/AI2.pm</code>, <code>t/ai2_chat_persist_exchange.t</code></p>
</div>
