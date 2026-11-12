<div id="2026-11-08-worktrees-json-symlink" class="cl-entry">
<h3>2026-11-08 — Share worktrees.json by symlink</h3>
<p class="doc-body"><strong>What.</strong> A new worktree now gets a symlink at <code>root/config/worktrees.json</code> pointing at the primary checkout's registry. Checkouts that had no file (healthkitchen, ency, Bmaster, DockerHA, Proxmox, codeguard) were linked the same way.</p>
<p class="doc-body"><strong>Why.</strong> The registry is excluded from git so merges do not fight over it. A new checkout therefore had no file, and its Develop Servers list showed only main. Copying the file back into git would restart those conflicts.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Git.pm</code> (<code>_ensure_worktree_config_link</code>, called from <code>create_worktree</code>). Existing regular copies were left in place. <code>t/util_git_create_worktree.t</code> now asserts the link lands where the checkout's app reads it (<code>&lt;gitroot&gt;/Comserv/root/config/worktrees.json</code>) and nowhere else.</p>
</div>
