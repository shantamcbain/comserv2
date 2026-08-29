<div id="2026-08-28-db-user-role-split" class="cl-entry">
<h3>2026-08-28 — Role-based DB users: comserv_app primary, shanta_forager fallback</h3>
<p class="doc-body"><strong>What.</strong> Split the single hardcoded <code>shanta_forager</code> runtime DB user into a
role-based set managed through the existing <code>~/.comserv/secrets/dbi/*.json</code> (K8s Secrets) files.
<code>db_production_mysql.json</code> now carries three prioritized connections for the <code>ency</code> database:
<code>comserv_app</code> (priority 1, app runtime, limited DML), <code>comserv_admin</code> (priority 2, DDL/schema work),
and <code>shanta_forager</code> (priority 3, safe fallback backup). Competing connections
(<code>production_server.json</code>, <code>docker_ency.json</code>) had their priorities lowered so
<code>comserv_app</code> wins once its MariaDB account exists with host <code>%</code>.</p>
<p class="doc-body"><strong>Why.</strong> The app should connect as a least-privilege <code>comserv_app</code> account, not a
full-access personal user. Admins needed visibility/control over which DB user is active, and schema-compare
(DDL) needs elevated rights without granting them to the runtime user.</p>
<p class="doc-body"><strong>Files.</strong>
<code>lib/Comserv/Model/DBEncy.pm</code> (trusts RemoteDB priority selection; logs <code>error</code>-level when
<code>comserv_app</code> is not the active user so it surfaces as a GUI alert),
<code>lib/Comserv/Controller/Admin/SchemaComparison.pm</code> (DDL runs as <code>comserv_admin</code>),
<code>lib/Comserv/Controller/Admin.pm</code> + <code>root/admin/index.tt</code> (DB-user dropdown inside the Database
Management card, preselects active user, optional password box),
<code>lib/Comserv/Controller/Api.pm</code> (<code>POST /api/db/switch_user</code> reads password from the secret JSON,
reconnects in-process, redirects back to <code>/admin</code>),
<code>lib/Comserv/Controller/Root.pm</code> + <code>root/pagetop.tt</code> + <code>root/Navigation/navigation.tt</code>
(active DB user shown in the footer / nav indicator).</p>
<p class="doc-body"><strong>Status.</strong> Code complete and compiles. Switch to <code>comserv_app</code> is gated only by the
MariaDB side: the <code>comserv_app</code>@<code>%</code> account must exist with the matching password. Until then the
app safely stays on <code>shanta_forager</code> (priority 3).</p>
</div>
