<div id="2026-08-20-branch-focus-queue" class="cl-entry">
<h3>2026-08-20 — Branch Daily Plan shows only that project's todos + blockers</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-20 | Version: 1.00 | Tracked in project: <a href="/project/details?project_id=138" class="doc-link">#138 (PLANNING)</a>.</p>
            <p class="doc-body">On a worktree server, <code>/planning/daily</code> no longer dumps the whole site Focus Queue. It keeps todos on the branch's project tree (root + phase children) and todos that actually block that project (<code>blocked_by_todo_id</code> or an active cross-project <code>is_blocking</code> dependency). <code>main</code> is unchanged. <code>?filter_project=all</code> is the escape hatch; <code>?filter_project=N</code> on a branch uses N as the root.</p>
            <ul class="doc-body">
                <li>Branch &rarr; project comes from <code>root/config/worktrees.json</code> <code>project_id</code>, then a name/code/<code>Branch:</code> comment match.</li>
                <li>Known links: planning #138, git #238, aisystem #280, DockerHA #202, 3d #272. InventoryAccounting still resolves by name until stamped.</li>
            </ul>
            <p class="doc-body">Files: <code>lib/Comserv/Controller/Planning.pm</code>, <code>lib/Comserv/Util/FocusRanking.pm</code>, <code>lib/Comserv/Util/ProjectDependencies.pm</code>, <code>lib/Comserv/Util/Git.pm</code>, <code>root/config/worktrees.json</code>, <code>root/admin/planning/_today_work_tab.tt</code>, <code>t/util_todo_ranking.t</code>.</p>
        </div>
    </div>
</div>
</div>
