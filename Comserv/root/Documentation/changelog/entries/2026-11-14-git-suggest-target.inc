<div id="2026-11-14-git-suggest-target" class="cl-entry">
<h3>2026-11-14 — Git Suggest refuses an unknown target</h3>
<p class="doc-body"><strong>What.</strong> Suggest commit message now binds the posted repo and returns the resolve error when the key is not in the host table or <code>external_repos</code>. The dashboard looks up the target selector inside the click handler.</p>
<p class="doc-body"><strong>Why.</strong> <code>_bind_target</code> only stashes the param. An unknown target used to look like “nothing to draft” and stay on the Comserv checkout. The selector name was also only in the outer closure, so a moved handler would throw and kill Suggest.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/root/static/js/git-dashboard.js</code>, <code>Comserv/t/git_suggest_target.t</code></p>
</div>
