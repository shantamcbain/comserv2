<div id="2026-08-18-git-worktree-port-collision-fix" class="cl-entry">
<h3>2026-08-18 — Git Worktree port-allocation collision fix</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-18 | Version: 1.0 | Owning plan: <a href="/Documentation/git_worktree_new_system_plan" class="doc-link">git_worktree_new_system_plan (v0.2.1)</a> — project <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>. Folded here from a standalone dated changelog file (policy: single CHANGELOG.tt).</p>
            <p class="doc-body"><strong>Symptom:</strong> creating a new worktree branch assigned it a port already in use. A new branch came up on <strong>4004</strong> — the port the <code>git</code> worktree (branch <code>git-dev</code>) was already serving. The Branch Servers list then showed two entries pointing at the same port.</p>
            <p class="doc-body"><strong>Root cause:</strong> <code>Util::Git-&gt;next_free_port</code> (and <code>create_worktree</code>) read the module-level cached <code>worktrees.json</code> map (<code>$_wt_config</code>) rather than the live file. On a multi-worker Catalyst server each worker holds its own cache; once primed it was never invalidated when another worker wrote a new branch+port. The allocator kept serving a stale port set.</p>
            <p class="doc-body"><strong>Fix</strong> (in <code>lib/Comserv/Util/Git.pm</code>, no schema/API change):</p>
            <ul class="doc-body">
                <li><code>_worktree_config</code> is now mtime-aware: re-reads the file whenever the on-disk mtime changes.</li>
                <li>Added <code>_worktree_json_fresh</code> — a cache-bypassing direct read — and routed the allocation path (<code>next_free_port</code> + <code>create_worktree</code>) through it.</li>
                <li><code>create_worktree</code> re-reads the live JSON right before writing, discards a port claimed in the interim, and merges its branch into the current on-disk map.</li>
            </ul>
            <p class="doc-body"><strong>Tests:</strong> new <code>t/util_git_next_free_port.t</code> (7 cases); <code>t/util_git_create_worktree.t</code> (13 cases) still green.</p>
            <p class="doc-body"><strong>Registry correction (same day):</strong> <code>git</code> (git-dev) → 4004; <code>planning</code> → 4005. Final map: 4001 InventoryAccounting, 4002 DockerHA, 4003 3d, 4004 git, 4005 planning.</p>
            <p class="doc-body">See <a href="/Documentation/git_worktree_new_system_plan#changelog" class="doc-link">git_worktree_new_system_plan §12 Changelog (v0.2.1)</a>.</p>
        </div>
    </div>
</div>
</div>
