<div id="2026-08-19-hermes-no-nested-worktree" class="cl-entry">
<h3>2026-08-19 — Git dashboard Hermes launch must not use -w</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">The Git dashboard Develop Servers &quot;Hermes&quot; button copied <code>hermes chat -w</code>. That flag creates a nested <code>hermes/hermes-*</code> worktree + branch (often from <code>origin/main</code>), so the agent is not on the feature branch the user clicked. Comserv already isolates via <code>~/.comserv/worktrees/&lt;branch&gt;/Comserv</code>.</p>
            <ul class="doc-body">
                <li><code>Util::Git-&gt;build_worktree_list</code> now emits <code>cd &lt;git-root&gt; &amp;&amp; hermes chat</code> (no <code>-w</code>) for <code>main</code> and every registered branch.</li>
                <li>Plan + 3d branch context updated: never launch Hermes with <code>-w</code> from a Comserv worktree.</li>
            </ul>
            <p class="doc-body">Files: <code>lib/Comserv/Util/Git.pm</code>, <code>root/static/js/git-dashboard.js</code>, <code>root/Documentation/HermesBranchContextPlan.tt</code>. Tracked under <a href="/todo/details?record_id=2143" class="doc-link">todo #2143</a> / project <a href="/project/details?project_id=238" class="doc-link">#238 GITWT-NEW</a>.</p>
        </div>
    </div>
</div>
</div>
