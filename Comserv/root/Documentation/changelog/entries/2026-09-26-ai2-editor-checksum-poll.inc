<div id="2026-09-26-ai2-editor-checksum-poll" class="cl-entry">
<h3>2026-09-26 — AI2 editor checksum poll no longer piles requests</h3>
<p class="doc-body"><strong>What.</strong> <code>ai2editor/chat.js</code> auto-refresh now <code>clearInterval</code>s before starting, skips a tick while a checksum is in flight or the tab is hidden, and wires the Ace dirty listener once.</p>
<p class="doc-body"><strong>Why.</strong> One editor window on a slow/hung <code>:3001</code> fired <code>/ai2/file_checksum</code> every 4s without waiting for the previous fetch, so requests stacked and looked like a cascade. ZeroTier was not the cause.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/ai2editor/chat.js</code></p>
</div>
