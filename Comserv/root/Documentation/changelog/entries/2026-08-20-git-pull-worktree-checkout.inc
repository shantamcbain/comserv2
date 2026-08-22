<div id="2026-08-20-git-pull-worktree-checkout" class="cl-entry">
<h3>2026-08-20 — Git pull must not checkout main from a worktree</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body"><code>/admin/git_pull</code> on a worktree server (e.g. planning:4005) ran <code>git checkout main</code>, which git refuses with exit 128 (<code>already used by worktree</code> at the primary checkout). That was logged as ERROR at <code>git_run</code> and spawned an audit todo. <code>switch_branch</code> already refused this; <code>pull</code> and <code>delete_branch</code> did not.</p>
            <ul class="doc-body">
                <li>Shared <code>_checkout_collision_reason</code> used by switch / pull / delete — refuse before git runs.</li>
                <li>Controller no longer defaults a missing branch param to <code>main</code>; it uses the current checkout.</li>
                <li><code>_run</code> demotes leftover checkout-collision 128s to info so they do not create error todos.</li>
            </ul>
            <p class="doc-body">Files: <code>lib/Comserv/Util/Git.pm</code>, <code>lib/Comserv/Controller/Admin/Git.pm</code>, <code>t/util_git.t</code>. Git dashboard / worktree isolation is project <a href="/project/details?project_id=238" class="doc-link">#238 GITWT-NEW</a>.</p>
        </div>
    </div>
</div>
</div>
