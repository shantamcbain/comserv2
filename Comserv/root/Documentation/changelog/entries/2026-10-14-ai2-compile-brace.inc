<div id="2026-10-14-ai2-compile-brace" class="cl-entry">
<h3>2026-10-14 — AI2 compile error blocked :3001</h3>
<p class="doc-body"><strong>What.</strong> Removed a stray <code>}</code> after <code>editing_widget_popup</code> that aborted compilation of <code>AI2.pm</code>. Added the <code>_is_shanta_editor</code> and <code>_is_dev_mode</code> helpers that action already called.</p>
<p class="doc-body"><strong>Why.</strong> Catalyst could not load the controller, so the :3001 restarter died on startup. The helpers were referenced with no definition, which would 500 the editor popup once the file compiled.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/AI2.pm</code></p>
</div>
