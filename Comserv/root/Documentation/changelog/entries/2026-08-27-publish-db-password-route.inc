<div id="2026-08-27-publish-db-password-route" class="cl-entry">
<h3>2026-08-27 — Publish Change DB password on Admin and Schema Compare</h3>
<p class="doc-body"><strong>What.</strong> The password form is at <code>/remotedb/change_password/&lt;slot&gt;</code>. Admins now reach the server list (<code>/remotedb</code>, then Password) from Admin Database Management, the Admin top menu, Schema Compare header, and a note on the env-var page (which is not the DB password tool).</p>
<p class="doc-body"><strong>Why.</strong> The route existed but was not listed next to Schema Compare / DB Passwords / Env, so admins could not find it.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/admin/index.tt</code>, <code>root/Navigation/admintopmenu.tt</code>, <code>root/admin/schema_compare/schema_compare.tt</code>, <code>root/admin/environment_variables/list.tt</code>.</p>
</div>
