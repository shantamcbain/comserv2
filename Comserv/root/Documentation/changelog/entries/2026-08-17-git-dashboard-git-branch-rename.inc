<div id="2026-08-17-git-dashboard-git-branch-rename" class="cl-entry">
    <h2>2026-08-17 — Git Dashboard: rename `git` worktree branch to `git-dev` to unblock merges</h2>
    <p><strong>Last Updated:</strong> 2026-08-17 | <strong>Version:</strong> 1.00 | <strong>Author:</strong> hermes | <strong>Status:</strong> Fixed (linked to project #238 GITWT-NEW)</p>

    <h3>Problem</h3>
    <p>The zenflow worktree at <code>~/.comserv/worktrees/git/Comserv</code> tracked a branch literally named <code>git</code>. That name collides with the <code>git</code> command itself, so <code>git checkout git</code> / <code>git switch git</code> are ambiguous and <strong>merges of that branch fail</strong> (the dashboard reported "Failed to switch to or create branch 'git'"). The Git Dashboard offered the <code>git</code> branch in its Switch dropdown and validated it as "known", then died on checkout.</p>

    <h3>Fix</h3>
    <ul>
        <li><strong>Branch renamed</strong> <code>git</code> &rarr; <code>git-dev</code> from inside the worktree (<code>git branch -m git git-dev</code>), preserving its 1 unique commit (<code>67cbb177</code>). The worktree now tracks <code>git-dev</code>; no code/commits lost.</li>
        <li><strong><code>Comserv/Util/Git.pm</code> &rarr; <code>get_local_branches</code></strong>: skip a branch literally named <code>git</code> (reserved word). This removes it from the dashboard dropdown <em>and</em> from the validation hash used by the switch/delete handlers — defense in depth against any future <code>git</code>-named branch.</li>
        <li><strong><code>Comserv/Controller/Admin/Git.pm</code> &rarr; <code>op=switch</code></strong>: explicitly reject <code>branch=git</code> with a clear "reserved" message (also protects <code>op=delbranch</code>, which shares the same validation).</li>
    </ul>

    <h3>Why not just add a rename button</h3>
    <p>A dashboard "rename branch" feature does not exist yet (confirmed: no endpoint, no UI). The <code>git</code>&rarr;<code>git-dev</code> rename was done at the shell to unblock work immediately. A first-class Rename-branch control is now on the backlog — see <a href="/Documentation/plans/2026-08-17-git-dashboard-merge-ui" class="doc-link">git-dashboard-merge-ui plan, &sect;7.1</a> (project GITWT-NEW #238).</p>

    <h3>Verified</h3>
    <ul>
        <li>Both controllers compile: <code>perl -Ilib -c</code> &rarr; syntax OK.</li>
        <li><code>admin/git/index.tt</code> renders clean (TT cache disabled): RENDER OK, exit 0.</li>
        <li><code>git-dev</code> present in <code>get_local_branches</code> output; literal <code>git</code> excluded (verified against real repo).</li>
        <li>Worktree reports <code>[git-dev]</code>; <code>git rev-list --left-right --count main...git-dev</code> &rarr; <code>1 0</code> (1 commit ahead, 0 behind).</li>
    </ul>

    <h3>Files touched</h3>
    <ul>
        <li><code>lib/Comserv/Util/Git.pm</code> — <code>get_local_branches</code> skips reserved <code>git</code> branch.</li>
        <li><code>lib/Comserv/Controller/Admin/Git.pm</code> — <code>op=switch</code> rejects <code>branch=git</code>.</li>
        <li><code>root/Documentation/plans/2026-08-17-git-dashboard-merge-ui.md</code> — &sect;7.1 backlog (rename-branch feature), &sect;8 status.</li>
    </ul>

    <h3>See also</h3>
    <ul>
        <li><a href="/Documentation/plans/2026-08-17-git-dashboard-merge-ui" class="doc-link">2026-08-17 Git Dashboard Merge UI plan</a> — the merge feature (main&rarr;branch, branch&rarr;main) still to be built into the dashboard; the <code>git</code>&rarr;<code>git-dev</code> rename unblocks it.</li>
    </ul>
</div>
