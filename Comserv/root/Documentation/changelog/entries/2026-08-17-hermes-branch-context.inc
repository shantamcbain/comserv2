<div id="2026-08-17-hermes-branch-context" class="cl-entry">
<h3>2026-08-17 — Hermes Branch Context system</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-17 | Version: 0.1 | Tracked in project: <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>. Folded here from a standalone dated changelog file (policy: single CHANGELOG.tt).</p>
            <h4 class="doc-h3">What changed</h4>
            <ul class="doc-body">
                <li><strong>Branch <code>.hermes.md</code> domain files</strong> written for the then-6 existing worktrees: InventoryAccounting, 3d, DockerHA, ai, aichatsystem-ef4e, git. Each re-includes the global <code>/home/shanta/PycharmProjects/comserv2/.hermes.md</code> then adds domain expertise. BMaster (beekeeping) deferred until its worktree exists. Status later corrected on 2026-08-19 (files were not actually on disk until then; planning added).</li>
                <li><strong>Git dashboard &quot;Hermes&quot; button</strong> — <code>Util/Git.pm -&gt; build_worktree_list</code> emits <code>hermes_cmd</code>; <code>root/admin/git/index.tt</code> adds the button (and fixes Open to use an absolute <code>scheme://host:port/path</code> URL); <code>root/static/js/git-dashboard.js</code> copies the command to clipboard. Later corrected: do not copy <code>hermes chat -w</code> (that flag nests a <code>hermes/hermes-*</code> scratch branch).</li>
                <li><strong>Planning plan doc</strong> — <a href="/Documentation/HermesBranchContextPlan" class="doc-link">/Documentation/HermesBranchContextPlan</a>, tracked under #238 with todos 2142–2146 (2146 recurring re-audit, set recurrence in the Todo UI).</li>
                <li><strong>MASTER_PLAN</strong> — new index row + &quot;Hermes Context&quot; navlink; back-links added from the sibling git-worktree plans.</li>
            </ul>
            <p class="doc-body">Why: each worktree is its own git root, so Hermes does not inherit the repo-root global rules. Related: <a href="/Documentation/HermesBranchContextPlan" class="doc-link">Hermes Branch Context Plan</a>, <a href="/Documentation/CHANGELOG#2026-08-19-hermes-branch-context-authoring" class="doc-link">2026-08-19 authoring correction</a>.</p>
        </div>
    </div>
</div>
</div>
