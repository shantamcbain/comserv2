<div id="2026-11-13-add-herb-ai-keys" class="cl-entry">
<h3>2026-11-13 — Add-herb AI model list no longer dies on missing key columns</h3>
<p class="doc-body"><strong>What.</strong> Looking up API keys for the add-herb Ask AI panel no longer selects <code>key_type</code>, <code>base_url</code>, or <code>label</code> when those columns are not on the live table. The dropdown was stuck on “Grok Beta (loading…)”.</p>
<p class="doc-body"><strong>Why.</strong> The Result class lists those columns, but <code>user_api_keys</code> does not have them yet. The full-row SELECT threw, so no Grok models were returned. Apply the columns with schema-compare; do not hand-write the ALTER.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Schema/Ency/ResultSet/UserApiKeys.pm</code>, <code>lib/Comserv/Model/Schema/Ency/Result/UserApiKeys.pm</code>, <code>root/ENCY/partials/AiFormFill.tt</code></p>
</div>
