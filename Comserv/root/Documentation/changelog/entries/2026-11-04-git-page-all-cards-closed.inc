<div id="2026-11-04-git-page-all-cards-closed" class="cl-entry">
<h3>2026-11-04 — Git Dashboard: every card starts closed</h3>
<p class="doc-body"><strong>What.</strong> <code>/admin/git</code> opened with the Working Tree card (a full file table plus
three forms) and the Develop Servers table (one row per worktree) already expanded, above five collapsed sections &mdash; the page
began three screens down. Now <strong>every</strong> card is a closed native <code>&lt;details&gt;</code>: the three strip cards
(Host, Repository, Remote), New Branch + Worktree (was an <code>admin-panel</code>), Working Tree (was an
<code>admin-panel</code>), Develop Servers (had a hard-coded <code>open</code>), Update all from main, Merge, Branches, Recent
Commits and Stashes.</p>
<p class="doc-body"><strong>Two deliberate exceptions so nothing is lost.</strong></p>
<ul class="doc-body">
<li><strong>Update all from main re-opens itself</strong> (<code>[% IF update_all_result %] open[% END %]</code>) because the
Preview/Update result table is its own body &mdash; a closed card would hide the answer it was just asked for.</li>
<li><strong>The card you were working in stays open across the action reload.</strong> A git op reloads the page after ~1.5 s
(<code>reloadGitDashboardSoon</code>) and a merge reloads it too, which under a closed-by-default page would slam the Working Tree
shut after every Stage/Commit. <code>git-dashboard.js</code> now records the set of open cards in <code>sessionStorage</code>
(key = the summary label with counts and the branch pill stripped, so &ldquo;Develop Servers (16)&rdquo; and
&ldquo;Repository git-dev&rdquo; keep their keys when the numbers or the branch change) and restores it on load. A fresh visit or a
new tab still starts fully closed; the store is tab-scoped and cleared by the browser.</li>
</ul>
<p class="doc-body"><strong>Closed cards still say what is inside.</strong> Working Tree's summary shows the changed-file count (or
&ldquo;clean&rdquo;), Develop Servers keeps its count, and the Repository summary keeps the live branch pill, so the page reads as a
status list rather than a blank wall.</p>
<p class="doc-body"><strong>Why.</strong> The dashboard is used for one task at a time; four expanded panels pushed the card the
user actually needed off-screen on every visit, and on a worktree with a long status the Working Tree alone filled the viewport.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/admin/git/index.tt</code>,
<code>Comserv/root/static/css/git-dashboard.css</code>, <code>Comserv/root/static/js/git-dashboard.js</code></p>
<p class="doc-body"><strong>Verified.</strong> Template rendered offline through TT2 with a stub <code>c</code> (no variables
missing, tag counts balanced: 11 <code>details</code>/11 <code>summary</code>/46 <code>div</code>): 9 cards, 0 carrying
<code>open</code>, and exactly 1 (Update-all) when a result is present. The rendered page was loaded in the browser: all cards closed
on load, opening Working Tree and reloading re-opens only Working Tree, clearing <code>sessionStorage</code> returns to all closed.
<code>node --check</code> clean. The authenticated <code>:4004</code> page was not exercised (login wall); markup for it is the same
template just rendered.</p>
</div>
