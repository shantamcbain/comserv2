<div id="2026-11-04-git-update-all-and-worklog-clocks" class="cl-entry">
<h3>2026-11-04 — Update-all-from-main works, false merge blockers removed, work-log clock survives midnight</h3>
<p class="doc-body"><strong>What.</strong> Three defects closed on <code>git-dev</code>.</p>
<p class="doc-body"><strong>1. The &ldquo;Update all from main&rdquo; card did nothing when clicked.</strong> Two independent causes in
<code>root/admin/git/index.tt</code>: the card&rsquo;s buttons sat inside a <code>&lt;form&gt;</code> nested in the page&rsquo;s outer form
(so they belonged to no form), and seven <code>[%#</code> comments were terminated with <code>#]</code> instead of <code>%]</code>, so each
comment swallowed markup up to the next real <code>%]</code> &mdash; taking <code>&lt;details&gt;</code>, <code>&lt;summary&gt;</code> and the
form with it. The comments are fixed, the card is now a plain form post that works without JavaScript, and the JS only upgrades a click
to an AJAX call it can never swallow. The endpoint accepts GET, stores its result in the session for redisplay, and answers an expired
admin session with a JSON <code>403</code> instead of a login redirect, so a failure reports itself.</p>
<p class="doc-body"><strong>2. Preview skipped 12 of 16 worktrees for no reason.</strong> The dry run intersected &ldquo;dirty files&rdquo; with
&ldquo;files main changes&rdquo;, so <code>.zencoder/scripts/updateprompt.pl</code> &mdash; a mode-only typechange (<code>T</code>) whose
working copy is byte-identical to main&rsquo;s in every checkout &mdash; blocked whole branches. Each candidate is now re-checked with
<code>git diff --quiet main -- &lt;file&gt;</code> and only a real content difference blocks. The one genuine blocker was
<code>Comserv/root/config/worktrees.json</code>, the per-checkout registry: it is now untracked in all 26 repos
(<code>git rm --cached</code> + a local <code>.git/info/exclude</code> rule) and kept on disk.</p>
<p class="doc-body"><strong>3. A work log left open past midnight billed one minute.</strong> <code>_duration_hms</code> subtracted the end
clock time from the start, so 15:39 &rarr; 01:38 went negative and the floor turned it into <code>00:01:00</code>. It now adds the elapsed
days counted from the stored <code>start_date</code> (same day 119 min, across midnight 599 min, 23:50&rarr;00:20 30 min). <code>close_log</code>
refuses to bill a span over 12 hours (records 0 with a comment), and new <code>reap_orphan_logs</code> closes any open log whose todo is
already status 3/4 on both <code>toggle_start</code> and <code>close_log</code> &mdash; that is what kept a DONE todo showing as open.</p>
<p class="doc-body"><strong>Why.</strong> The bulk update is the only practical way to keep sixteen worktrees on main; a card that silently
does nothing made <code>main</code> unreachable from any branch. The clock errors corrupted billing for real work, and one of them
fabricated time on a finished todo.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>,
<code>Comserv/lib/Comserv/Util/TodoLog.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>,
<code>Comserv/lib/Comserv/Controller/Planning.pm</code>, <code>Comserv/lib/Comserv/Controller/Root.pm</code>,
<code>Comserv/root/admin/git/index.tt</code>, <code>Comserv/root/static/js/git-dashboard.js</code>,
<code>Comserv/root/js_load.tt</code></p>
<p class="doc-body"><strong>Not verified.</strong> The <code>Util/Git.pm</code> and <code>Util/TodoLog.pm</code> changes were not exercised
through the running <code>:4004</code> (the process predates them); a restart and one Preview/Update pass is still owed.</p>
</div>
