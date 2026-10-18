<div id="2026-10-05-fix-usage-monitor-templates" class="cl-entry">
<h3>2026-10-05 — Fix AI Usage Monitor card template parse errors (500)</h3>
<p class="doc-body"><strong>What.</strong> Fixed Template Toolkit parse errors on the AI Usage &amp; Activity Monitor page (<code>/ai/usage</code>). Removed an unresolved git merge conflict and converted invalid ternary <code>? ( ... | format(...) ) : ...</code> expressions to proper <code>IF ... ; ... | format ... ; ELSE; ... ; END</code> blocks in the fallover and health cards.</p>
<p class="doc-body"><strong>Why.</strong> The page returned "Internal Server Error" for admins. TT parser chokes on <code>|</code> filters inside ternary expressions and on <code>&lt;&lt;&lt;&lt;&lt;&lt;&lt; HEAD</code> markers left in the template.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/ai/usage_fallover_card.tt</code>, <code>Comserv/root/ai/usage_health_card.tt</code> (included by <code>ai/usage.tt</code>).</p>
</div>