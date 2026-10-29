<div id="2026-10-26-worktree-ff-catch-up" class="cl-entry">
<h3>2026-10-26 — Fast-forward idle worktrees after a land on main</h3>
<p class="doc-body"><strong>What.</strong> After a successful branch→main merge (<code>/admin/git/merge</code> and <code>/admin/git/merge_to_main</code>), registered worktrees that are clean and have no commits of their own are fast-forwarded onto <code>main</code>. Dirty trees and branches that are ahead of main are skipped and named in the merge result. The reverse direction is never automatic.</p>
<p class="doc-body"><strong>Why.</strong> Idle domain worktrees (Documentation was 613 behind with nothing of its own) go stale because nobody comes back to update them as a separate task. <code>--no-ff</code> the other way is the ping-pong loop. <code>--ff-only</code> moves the branch pointer and does not create a commit.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Git.pm</code> (<code>catch_up_registered_worktrees</code>, <code>--ff-only</code> allow-listed for that path only), <code>lib/Comserv/Controller/Admin/Git.pm</code>, <code>root/static/js/ai2editor/git-review.js</code>.</p>
</div>
