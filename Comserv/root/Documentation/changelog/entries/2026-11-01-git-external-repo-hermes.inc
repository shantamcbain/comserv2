<div id="2026-11-01-git-external-repo-hermes" class="cl-entry">
<h3>2026-11-01 — External git repo on the Git dashboard</h3>
<p class="doc-body"><strong>What.</strong> The git-dev dashboard can run git against a registered repo that is not a Comserv worktree. OpenBafangTool is the first one: Host link and Develop Servers row open <code>/admin/git?target=openbafang</code>, and the Hermes button opens the isolated dashboard on port 9120 in <code>/home/shanta/dev/OpenBafangTool</code>.</p>
<p class="doc-body"><strong>Why.</strong> The UART work stays in its own checkout. Copying those files into a Comserv worktree would mix two repositories. The Hermes click used to open the git page and then close the dashboard tab if the start call failed.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/config/worktrees.json</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/lib/Comserv/Util/BranchServerControl.pm</code>, <code>Comserv/root/admin/git/index.tt</code>, <code>Comserv/root/static/js/git-dashboard.js</code>.</p>
</div>
