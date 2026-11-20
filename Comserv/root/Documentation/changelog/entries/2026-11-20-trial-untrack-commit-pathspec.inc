<div id="2026-11-20-trial-untrack-commit-pathspec" class="cl-entry">
<h3>2026-11-20 - Merge untrack of trial state no longer reports a clean secret scan as the failure</h3>
<p class="doc-body"><strong>What.</strong> Merge main failed with "Could not untrack runtime trial state on main: No secrets detected in staged files." The secret scan was clean. <code>git commit -- &lt;path&gt;</code> rebuilds that path from the worktree, so a staged deletion was dropped while the file was still on disk and git exited 1 with "no changes added to commit." The untrack now moves the files aside, commits the absence, and puts them back. The clean-scan line is stripped from captured stderr so it cannot be reported as the reason.</p>
<p class="doc-body"><strong>Why.</strong> That refusal blocked every merge of main while the trial snapshots stayed tracked, and the message sent people to a manual untrack for a bug in the automatic commit.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code></p>
</div>
