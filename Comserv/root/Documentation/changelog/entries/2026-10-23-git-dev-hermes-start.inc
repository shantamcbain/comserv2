<div id="2026-10-23-git-dev-hermes-start" class="cl-entry">
<h3>2026-10-23 — git-dev Hermes start compiles again</h3>
<p class="doc-body"><strong>What.</strong> Removed committed merge markers in <code>build_worktree_list</code> that made <code>Git.pm</code> fail to compile, so the Hermes button's <code>BranchServerControl</code> load died before spawn. Kept main's isolated dashboard fields. <code>hermes_cwd_for</code> now finds a checkout whose directory name is not the branch (git-dev lives in <code>worktrees/git</code>).</p>
<p class="doc-body"><strong>Why.</strong> Clicking Hermes on the git-dev server never wrote <code>/tmp/hermes-dash-*.log</code> and never bound :9104, because the action could not load.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Git.pm</code>, <code>lib/Comserv/Util/BranchServerControl.pm</code></p>
</div>
