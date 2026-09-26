<div id="2026-09-25-schema-compare-live-source" class="cl-entry">
<h3>2026-09-25 — Schema-compare Create Table registers missing Result sources live</h3>
<p class="doc-body"><strong>What.</strong> <code>create_table_from_result</code> no longer dies with <code>Can't find source for HealthKitchen::UserActiveSymptom</code> (same for <code>UserHealthProfile</code>) on a long-lived <code>:4006</code> process. If the live schema object was frozen before those Result classes were added, the action now <code>require</code>s the class and <code>register_source</code>s it on the current schema instance, then deploys.</p>
<p class="doc-body"><strong>Why.</strong> Nested Health Kitchen Result files load from disk, but Catalyst's DBEncy schema object does not rescan <code>load_namespaces</code> until restart. Pantry/map tables had been created; symptom and profile Create Table hit the stale source list.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Admin/SchemaComparison.pm</code> (<code>_ensure_result_source</code>).</p>
</div>
