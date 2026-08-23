<div id="2026-08-19-hermes-branch-context-authoring" class="cl-entry">
<h3>2026-08-19 — Hermes Branch Context: authoring guideline + status correction</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-19 | Version: 0.1 | Tracked in project: <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>. Folded here from a standalone dated changelog file (policy: single CHANGELOG.tt).</p>
            <h4 class="doc-h3">What changed</h4>
            <ul class="doc-body">
                <li><strong>Authoring guideline added (new §3.3).</strong> <a href="/Documentation/HermesBranchContextPlan" class="doc-link">HermesBranchContextPlan</a> now has a concrete &quot;How to build a branch <code>.hermes.md</code>&quot; recipe: exact file path (<code>~/.comserv/worktrees/&lt;branch&gt;/Comserv/.hermes.md</code>, the worktree git root), the MANDATORY global-pointer header (point to <code>/home/shanta/PycharmProjects/comserv2/.hermes.md</code> — do NOT copy rules), required Branch identity / domain / worktree-rules blocks, port-from-worktrees.json rule, and a 4-point post-create verification (incl. asserting the GLOBAL file is unchanged).</li>
                <li><strong>Status correction.</strong> The prior plan asserted the branch <code>.hermes.md</code> files were &quot;DONE&quot; on 2026-08-17. They did NOT exist on disk then. The 7 active worktree files (planning, InventoryAccounting, 3d, DockerHA, ai, aichatsystem-ef4e, git) were actually created 2026-08-19 with the §3.3 template. The <code>planning</code> branch (missing from the original list of 6) is now included.</li>
                <li><strong>Incident recorded.</strong> A batch-seeding step overwrote the GLOBAL <code>/home/shanta/PycharmProjects/comserv2/.hermes.md</code> with a branch template; it was detected and the original 104-line global content restored verbatim. §3.3.4 + the §3.3 gotcha now forbid iterating over <code>main</code> with the branch template — the global path is read-only.</li>
                <li><strong>Plan bumped</strong> to page_version 0.2; todo 2142 gate text corrected; MASTER_PLAN nav + index already cross-link this doc.</li>
            </ul>
            <p class="doc-body">Related: <a href="/Documentation/HermesBranchContextPlan" class="doc-link">Hermes Branch Context Plan</a>, <a href="/Documentation/git_worktree_new_system_plan" class="doc-link">git_worktree_new_system_plan</a>, <a href="/Documentation/CHANGELOG#2026-08-17-hermes-branch-context" class="doc-link">2026-08-17 Hermes Branch Context</a>.</p>
        </div>
    </div>
</div>
</div>
