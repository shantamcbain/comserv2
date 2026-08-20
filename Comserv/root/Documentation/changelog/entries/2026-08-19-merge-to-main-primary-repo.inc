<div id="2026-08-19-merge-to-main-primary-repo" class="cl-entry">
<h3>2026-08-19 — In-app merge branch→main targets the primary repo + test-gate path fix</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">The Git dashboard / AI2 &quot;merge this branch into main&quot; path was a no-op or hard-blocked on every worktree branch. Two independent bugs, both in the code that runs on <code>main</code> (port 3001) — a fix that only lived on <code>planning</code> could never be merged through the broken gateway.</p>
            <ul class="doc-body">
                <li><strong>Test gate looked one directory too high.</strong> <code>run_test_gate</code> used <code>&lt;base&gt;/&lt;branch&gt;/Comserv</code> (the worktree git root) and fell back to <code>&lt;repo&gt;/script/test_gate.sh</code> where <code>repo</code> is the toplevel <code>comserv2/</code>. The script actually lives at <code>comserv2/Comserv/script/test_gate.sh</code>. Result: every merge reported <code>test_gate.sh not found</code> and blocked.</li>
                <li><strong><code>merge_to_main</code> tried to <code>switch_branch('main')</code>.</strong> On a linked worktree that fails (<code>main</code> is already checked out in the primary). Even without the switch, <code>git -C &lt;worktree&gt; merge --no-ff &lt;branch&gt;</code> merges the branch into itself → &quot;Already up to date&quot; and <code>main</code> is never touched.</li>
                <li><strong><code>git worktree list --porcelain</code> was refused</strong> (flag missing from the whitelist), so worktree list / primary-repo discovery failed closed.</li>
            </ul>
            <p class="doc-body"><strong>Fix:</strong> resolve the primary checkout via <code>git rev-parse --git-common-dir</code> (<code>main_repo_path</code>); run both the gate and <code>git merge --no-ff &lt;branch&gt;</code> with an explicit repo override; never switch branches; whitelist <code>--porcelain</code> and <code>--git-common-dir</code>; honor <code>COMSERV_DIR</code> in <code>test_gate.sh</code> so the running app's script tests the branch checkout. Same path is used by <code>POST /admin/git/merge_to_main</code> and the dashboard <code>POST /admin/git/merge</code> (branch→main).</p>
            <p class="doc-body">Files: <code>lib/Comserv/Util/Git.pm</code>, <code>lib/Comserv/Controller/Admin/Git.pm</code>, <code>script/test_gate.sh</code>, <code>t/util_git.t</code>. Tracked under <a href="/todo/details?record_id=2006" class="doc-link">todo #2006</a> / project <a href="/project/details?project_id=238" class="doc-link">#238 GITWT-NEW</a>.</p>
        </div>
    </div>
</div>
</div>
