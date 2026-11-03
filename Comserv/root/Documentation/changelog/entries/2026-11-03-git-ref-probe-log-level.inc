<div id="2026-11-03-git-ref-probe-log-level" class="cl-entry">
<h3>2026-11-03 - git ref existence probes are not errors</h3>
<p class="doc-body"><strong>What.</strong> <code>Comserv::Util::Git::_run</code> now logs a failing <code>git rev-parse --verify --quiet &lt;ref&gt;</code> as benign (info) when git exits 1 with empty stdout and stderr; an exit carrying a message (for example <code>fatal: not a git repository</code>) still logs at error.</p>
<p class="doc-body"><strong>Why.</strong> <code>rev-parse --verify</code> is the subsystem's existence probe - "the ref is not there" IS the answer <code>get_available_branches</code> and <code>catch_up</code> branch on. Logging that answer at ERROR created error-audit todo 2650, which fired whenever a worktree asked about an <code>origin</code> branch it had not fetched (<code>refs/remotes/origin/besst-uart-support</code>, three occurrences across :4004 and :4006).</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>.</p>
</div>
