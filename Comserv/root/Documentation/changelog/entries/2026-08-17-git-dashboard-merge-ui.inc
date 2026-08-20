<div id="2026-08-17-git-dashboard-merge-ui" class="cl-entry">
    <h2>2026-08-17 — Git Dashboard: Merge UI (main &rarr; branch, branch &rarr; main, one at a time)</h2>
    <p><strong>Last Updated:</strong> 2026-08-17 | <strong>Version:</strong> 1.00 | <strong>Author:</strong> hermes | <strong>Status:</strong> Shipped (linked to project #238 GITWT-NEW)</p>

    <h3>Problem</h3>
    <p>The Git Dashboard had no way to merge <code>main</code> into a selected branch (or a branch into <code>main</code>) from the browser — PyCharm-equivalent one-at-a-time merges had to be done by hand. Two blocking bugs were found and fixed in the process:</p>
    <ul>
        <li><strong>"Already up to date" lie (wrong merge source).</strong> The merge action merged <code>origin/main</code> rather than the local <code>main</code> ref. When local <code>main</code> had unpushed commits, <code>origin/main</code> was stale and <code>git merge origin/main</code> reported "Already up to date" even though <code>main</code>'s code was never delivered to the branch.</li>
        <li><strong>Vanishing result (wiped on success).</strong> The JS handler called <code>location.reload()</code> / <code>refreshGitDashboard()</code> on success, which re-rendered the Merge card and wiped the status + <code>&lt;pre&gt;</code> output before the user could read it — the result "disappeared almost instantly."</li>
        <li><strong>Worktree path resolution.</strong> <code>git worktree list --porcelain</code> drops the <code>worktree &lt;path&gt;</code> line for the <code>git-dev</code> worktree (stale metadata from the <code>git</code>&rarr;<code>git-dev</code> rename), so <code>worktree_checkout_path_for_branch</code> returned <code>undef</code> &rarr; "not checked out in any worktree."</li>
    </ul>

    <h3>Fix</h3>
    <ul>
        <li><strong><code>Controller::Admin::Git::merge</code> (POST /admin/git/merge)</strong> now merges the <strong>local <code>main</code></strong> ref (the code visible on the dashboard), not <code>origin/main</code>, for both the main&rarr;branch and branch&rarr;main worktree-sync paths. Both directions run <em>inside the branch's own worktree checkout</em> via <code>_run(..., { repo =&gt; $wt_path })</code>; a worktree branch is already checked out so it is never switched in the main repo (git refuses "already used by worktree").</li>
        <li><strong><code>Util::Git::worktree_checkout_path_for_branch</code></strong>: added a directory scan of the worktree base dir (<code>~/.comserv/worktrees/*/Comserv</code>) that matches each checkout's actual branch via <code>git branch --show-current</code>, bypassing the corrupt porcelain. Fixed the scan to test <code>-e</code> (exists) not <code>-d</code> — a worktree's <code>.git</code> is a <em>file</em> (gitdir pointer), not a directory.</li>
        <li><strong><code>root/static/js/git-dashboard.js</code></strong>: removed the auto-refresh/reload on merge success so the status badge + output <code>&lt;pre&gt;</code> stay visible until a manual hard-refresh. Added <code>console.log('[git-dashboard] merge response:', res)</code> so the full server response (incl. any error line) is captured in DevTools even if the DOM flashes.</li>
    </ul>

    <h3>How it works</h3>
    <ul>
        <li><strong>Merge main &rarr; branch</strong> (source=main, target=branch): <code>fetch origin</code> then <code>git -C &lt;worktree&gt; merge --no-ff main</code>. No test gate (updating a worktree, not main).</li>
        <li><strong>Merge branch &rarr; main</strong> (source=branch, target=main): <code>run_test_gate</code> blocks on red; optional best-effort sync of the branch's worktree to main; then <code>merge_branch($c, $source)</code> in the main repo.</li>
        <li><strong>Conflict</strong> &rarr; <code>{ conflict=&gt;1, output }</code>; the UI reveals a one-click <strong>Abort</strong> (POST /admin/git/merge/abort &rarr; <code>git merge --abort</code>).</li>
        <li>All git via <code>git_service</code> (<code>_run</code> whitelist); logged via <code>log_with_details</code>. Admin-gated <code>git_merge</code>; reserved <code>git</code> branch rejected.</li>
    </ul>

    <h3>Verified</h3>
    <ul>
        <li>Both modules compile: <code>perl -Ilib -c</code> &rarr; syntax OK.</li>
        <li><code>admin/git/index.tt</code> renders clean (TT cache disabled): RENDER OK.</li>
        <li><code>node --check root/static/js/git-dashboard.js</code> &rarr; OK.</li>
        <li>Dry run on the real <code>git-dev</code> worktree: <code>git -C ~/.comserv/worktrees/git/Comserv merge --no-ff --no-commit main</code> &rarr; "Automatic merge went well" bringing in the 4 local-main commits (previously "Already up to date" because it targeted stale <code>origin/main</code>); <code>--abort</code> cleaned up non-destructively.</li>
        <li><strong>Live:</strong> on <code>/admin/git</code> (port 3001), selecting <code>git-dev</code> &rarr; "Merge main &rarr; this branch" reports <strong>merged</strong> with the commit output staying visible, and the <code>git-dev</code> worktree now carries <code>main</code>'s code (Merge tab, branch-visibility fixes).</li>
    </ul>

    <h3>Files touched</h3>
    <ul>
        <li><code>lib/Comserv/Controller/Admin/Git.pm</code> — <code>merge</code> action: merge local <code>main</code> (not <code>origin/main</code>); <code>merge_abort</code> action already present.</li>
        <li><code>lib/Comserv/Util/Git.pm</code> — <code>worktree_checkout_path_for_branch</code>: directory-scan resolution by actual branch (<code>-e</code> not <code>-d</code>).</li>
        <li><code>root/static/js/git-dashboard.js</code> — sticky merge result (no auto-reload); console capture of response.</li>
        <li><code>root/admin/git/index.tt</code> — Merge <code>&lt;details&gt;</code> card (built in prior work).</li>
        <li><code>root/Documentation/plans/2026-08-17-git-dashboard-merge-ui.md</code> &mdash; &sect;3 direction logic corrected (worktree-internal merge), &sect;8 status updated to Shipped.</li>
    </ul>

    <h3>See also</h3>
    <ul>
        <li><a href="/Documentation/plans/2026-08-17-git-dashboard-merge-ui" class="doc-link">2026-08-17 Git Dashboard Merge UI plan</a> &mdash; &sect;7.1 backlog: first-class "Rename branch" control (the <code>git</code>&rarr;<code>git-dev</code> rename was done at the shell for now).</li>
        <li><a href="/Documentation/changelog/CHANGELOG#2026-08-17-git-dashboard-git-branch-rename" class="doc-link">2026-08-17 Git Dashboard branch rename</a> &mdash; the rename that unblocked this feature.</li>
    </ul>
</div>
