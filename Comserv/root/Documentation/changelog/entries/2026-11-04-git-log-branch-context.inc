<div id="2026-11-04-git-log-branch-context" class="cl-entry">
<h3>2026-11-04 — Git failures now say which branch and checkout they happened in</h3>
<p class="doc-body"><strong>Problem.</strong> The health panel showed four identical rows
<code>git merge --no-ff --no-edit main -&gt; exit=2 out= error: Your local changes to the following files would be
overwritten by merge ...</code> from <code>workstation (Standalone):4004</code>. The only thing that varied was the file list,
so nothing said <em>which</em> worktree was blocked &mdash; the system identifier names the port, not the branch, and the message
carried no repo path at all. A bulk update loads every worktree, so every failing branch produced the same line.</p>
<p class="doc-body"><strong>Fix 1 &mdash; context on every git log line.</strong> <code>Comserv::Util::Git::_run</code> now prefixes
its <code>git_run</code> detail with a target tag built by the new <code>_log_where</code> /
<code>_checkout_branch</code> helpers: <code>[branch=git-dev worktree=git repo=/home/&hellip;/worktrees/git/Comserv]</code> for a local
checkout, <code>[host=workstation(192.168.1.20) user=shanta repo=&lt;path on that host&gt;]</code> for an SSH target
(<code>_ssh_exec_git</code> gets the same tag). The branch comes from <code>git rev-parse --abbrev-ref HEAD</code>, run
<strong>only when the command failed</strong> (a detached HEAD reports <code>detached</code>), so successful calls pay nothing, and a
failure in the log can be placed without cross-referencing the timestamp with a worktree list.</p>
<p class="doc-body"><strong>Fix 2 &mdash; a dirty worktree is a warning, not an ERROR.</strong> &ldquo;Your local changes would be
overwritten by merge&rdquo; is an expected, already-classified outcome: <code>update_all_from_main</code> turns it into a
<code>skipped_local_changes</code> row with the file list, and <code>merge_branch</code> into <code>uncommitted</code>. It was being
logged at ERROR by <code>_run</code> on top of that classification, which is what filled the health panel and would have spawned
error-audit todos for worktrees that need a commit, not a git repair. It is now logged at <code>warn</code> (still written to the DB
log), the same treatment a merge CONFLICT already got.</p>
<p class="doc-body"><strong>Fix 3 &mdash; the bulk-update summary names the branches.</strong> The
<code>git_merge</code> summary line recorded only counts (&ldquo;4 skipped_local_changes&rdquo;). It now ends with
<code>Needs attention: git=git-dev (:4004) skipped_local_changes [.hermes.md, &hellip;; &hellip;]</code> for every row in
<code>skipped_local_changes</code>/<code>failed</code>/<code>conflict</code>/<code>blocked</code>, and is logged at
<code>warn</code> when such a row exists, so one line in the panel answers &ldquo;which branch do I fix?&rdquo;.</p>
<p class="doc-body"><strong>Why.</strong> The information existed in the returned rows and in the page, but the log is what gets
read first (and what the health alert shows); an unplaceable ERROR row costs a manual timestamp-to-worktree investigation every
time.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code></p>
<p class="doc-body"><strong>Verified.</strong> <code>perl -Ilib -c lib/Comserv/Util/Git.pm</code>; a scratch repo whose branch has an
uncommitted edit to a file main changes reproduces the exact <code>exit=2</code> refusal and now logs
<code>WARN git_run [branch=feature repo=&hellip;] git merge --no-ff --no-edit main -&gt; exit=2 &hellip;</code>; a scratch
<code>update_all_from_main</code> run logs
<code>WARN git_merge Update all from main: 1 skipped_local_changes. Needs attention: alpha=alpha (:4001) skipped_local_changes [f.txt]</code>.
Both against a stub log sink, not the running server.</p>
</div>
