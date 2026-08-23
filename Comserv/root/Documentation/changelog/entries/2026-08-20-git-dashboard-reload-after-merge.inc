<div id="2026-08-20-git-dashboard-reload-after-merge" class="cl-entry">
<h3>2026-08-20 — Git dashboard reloads after a successful merge</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-20 | Version: 1.00 | Tracked in project: <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>.</p>
            <p class="doc-body">After a successful merge on <code>/admin/git</code>, the dashboard now reloads so ahead/behind and working-tree counts match the new HEAD. The merge badge and output are stashed in <code>sessionStorage</code> and restored after reload, so the result does not vanish (the 2026-08-17 vanishing-result bug). Conflicts and failures stay on the current page and do not reload.</p>
            <p class="doc-body">File: <code>root/static/js/git-dashboard.js</code>.</p>
        </div>
    </div>
</div>
</div>
