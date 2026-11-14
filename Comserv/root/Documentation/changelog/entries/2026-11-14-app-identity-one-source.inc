<div id="2026-11-14-app-identity-one-source" class="cl-entry">
<h3>2026-11-14 — Phone and web debug bar report the same server</h3>
<p class="doc-body"><strong>What.</strong> <code>/api/app/ping</code>, <code>/api/app/version</code> <code>serverInfo</code>, and <code>/api/app/server-info</code> now take branch, commit, and workflow from the checkout the process is running. <code>git</code> on server-info and version is the same <code>branch@commit</code> string the web debug bar prints.</p>
<p class="doc-body"><strong>Why.</strong> Ping read <code>COMSERV_ROOT</code>, which defaults to the primary tree, so a worktree server told the phone it was <code>main</code>. Version called <code>Git-&gt;current_head_str</code>, which does not exist, and fell back to <code>main</code>. Server-info already knew the live checkout but returned <code>git</code> as an object, which the phone's string field dropped, so the health screen also showed <code>main</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Api.pm</code></p>
</div>
