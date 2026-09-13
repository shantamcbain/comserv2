<div id="2026-08-27-remotedb-change-password" class="cl-entry">
<h3>2026-08-27 — Change DB password from /remotedb</h3>
<p class="doc-body"><strong>What.</strong> Admin form at <code>/remotedb/change_password/&lt;slot&gt;</code> updates the stored password in <code>db_config.json</code> and <code>~/.comserv/secrets/dbi/</code>, optionally the same-password sibling slots, and optionally <code>ALTER USER USER()</code> on MariaDB. No <code>db_config.json.backup.*</code> dump is written.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2305: live DB password was in tracked backups. Rotation has to happen in the app, not by copying JSON around.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/DbConfigPassword.pm</code>, <code>lib/Comserv/Controller/RemoteDB.pm</code>, <code>root/remotedb/change_password.tt</code>, <code>root/remotedb/detail.tt</code>, <code>root/remotedb/index.tt</code>, <code>t/util_db_config_password.t</code>.</p>
</div>
