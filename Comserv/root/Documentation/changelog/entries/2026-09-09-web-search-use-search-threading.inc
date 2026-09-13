<div id="2026-09-09-web-search-use-search-threading" class="cl-entry">
<h3>2026-09-09 — Web search toggle never reached the provider (use_search dropped)</h3>
<p class="doc-body"><strong>What.</strong> The chat widget's "🔍 Web" checkbox set
<code>use_search</code>, and <code>Grok.pm</code> already implemented the
matching <code>search_parameters: {mode:'auto'}</code> — but the flag was
dropped between them, so web search never actually ran.</p>
<p class="doc-body"><strong>Why.</strong> <code>local-chat.js</code> set the flag,
<code>AI2.pm</code> read it and passed it into <code>Chat-&gt;process</code>, but
<code>Chat.pm</code> and <code>Router.pm</code> contained no reference to
<code>use_search</code> at all. <code>chat_with_fallback</code> and
<code>_chat_one</code> built their provider argument lists without it, so
<code>Grok.pm</code> always saw it as false.</p>
<p class="doc-body"><strong>Fix.</strong> Threaded the flag through the call
chain as an options hash: <code>Chat.pm</code> passes
<code>use_search =&gt; 1</code> into <code>chat_with_fallback</code>, which
forwards to <code>_chat_one_with_retry</code> and then <code>_chat_one</code>,
which injects it into the provider <code>chat()</code> call. Injected only when
truthy, so the default path is unchanged.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code>,
<code>Comserv/lib/Comserv/Model/AI2/Router.pm</code></p>
<p class="doc-body"><strong>Verification.</strong> <code>perl -c</code> clean on
both. A 4-assertion harness with a stub provider confirms
<code>use_search=1</code> arrives at the provider, that omitting it or passing
<code>0</code> leaves it absent (no behaviour change), and that other
arguments still pass through intact.</p>
<p class="doc-body"><strong>Note.</strong> This restores the toggle; it does not
by itself make search succeed — the Grok hop currently returns 403
(personal-team-blocked:spending-limit), so a working backend still depends on
quota or a different search provider.</p>
</div>
