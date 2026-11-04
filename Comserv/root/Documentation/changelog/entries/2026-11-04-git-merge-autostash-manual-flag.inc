<div id="2026-11-04-git-merge-autostash-manual-flag" class="cl-entry">
<h3>2026-11-04 — Bulk merge really merges everything it can, and flags the branches a human must finish</h3>
<p class="doc-body"><strong>Problem.</strong> One uncommitted file blocked an entire branch. <code>git merge</code> refuses the whole
merge when main touches <em>any</em> dirty file ("Your local changes would be overwritten"), so a worktree with 100 commits of incoming
changes and two edited files received <strong>none</strong> of them — row <code>skipped_local_changes</code>, and the same branches
reported as blocked on every run. That is the "auto merge is not really merging the non-conflicting files" complaint.</p>
<p class="doc-body"><strong>Fix 1 — retry with git's own <code>--autostash</code>.</strong> On that refusal the merge is re-attempted as
<code>merge --no-ff --no-edit --autostash main</code> (or <code>--ff-only --autostash</code>): git stores the dirty files, merges
everything that does not conflict, then re-applies the edits. Nothing is discarded, nothing is forced, no reset, no rebase.</p>
<p class="doc-body"><strong>Fix 2 — a flag for manual intervention.</strong> Every row a human must finish now carries
<code>needs_manual</code>: <code>merged_manual</code> (main merged, but the re-applied edit collided — the worktree keeps the conflict
markers and the edits stay in <code>git stash list</code>, with <code>manual_files</code> naming them), plus <code>conflict</code>,
<code>blocked</code>, <code>failed</code> and the residual <code>skipped_local_changes</code>. The result table gained a
<strong>Manual</strong> column (<span style="color:#dc3545;">&#9873; needs manual</span>) with the conflicted files and the stash entry,
and the summary line ends with <code>Needs attention: planning=planning (:4005) merged_manual [.hermes.md]</code>. Preview changed too:
overlapping dirty files are now predicted as <code>would_merge_autostash</code> instead of "skipped".</p>
<p class="doc-body"><strong>Fix 3 — &ldquo;uptodate&rdquo; no longer hides a branch that has its own commits.</strong> The old row said
<code>uptodate</code> whenever the branch was 0 commits <em>behind</em> main, so <code>git-dev</code> (0 behind, 1 ahead — its own
commit) read as &ldquo;up to date with main&rdquo; and a clean tree read as &ldquo;nothing changed&rdquo;. Now: <code>in_sync</code> only
when 0 behind AND 0 ahead, <code>ahead_only</code> when 0 behind but N ahead (reason: <em>N commit(s) main does not have — nothing to
merge</em>), and every row whose working tree was actually inspected carries a separate tree state (<code>tree clean</code> /
<code>N uncommitted</code>) shown under the Result — rows that were skipped, missing or failed before inspection show no tree
state at all, never a false &ldquo;tree clean&rdquo;. Every <code>action</code>/<code>tree</code>/<code>reason</code> cell in the
result table is now HTML-escaped. Working-tree cleanliness and sync-with-main are two different facts and are now reported as two.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/root/admin/git/index.tt</code>,
<code>Comserv/root/static/js/git-dashboard.js</code></p>
<p class="doc-body"><strong>Verified.</strong> Scratch three-branch run: conflicting local edit &rarr; <code>merged_manual</code>,
incoming file present, edit kept in conflict markers, <code>stash@{{0}}</code> kept, flagged; unrelated dirty file &rarr;
<code>merged</code> clean, edit intact; dirty file identical to main's version &rarr; <code>merged</code> via autostash. Template
rendered with a <code>merged_manual</code> row: 9 header columns, 9 cells per row, flag only on that row, autostash/stash shown.
<code>perl -Ilib -c</code> and <code>node --check</code> clean.</p>
</div>
