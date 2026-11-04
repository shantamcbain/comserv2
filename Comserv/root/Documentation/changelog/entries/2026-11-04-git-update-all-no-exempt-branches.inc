<div id="2026-11-04-git-update-all-no-exempt-branches" class="cl-entry">
<h3>2026-11-04 — Update-all merges every worktree: Proxmox (:4016) and 3d (:4003) are no longer exempt</h3>
<p class="doc-body"><strong>What.</strong> The &ldquo;Update all branches from main&rdquo; card carried two exemptions that had nothing behind them:
<code>%UPDATE_ALL_ALWAYS_SKIP = (Proxmox =&gt; 1)</code> / <code>%UPDATE_ALL_SKIP_PORTS = (4016 =&gt; 1)</code> refused Proxmox outright,
and <code>%UPDATE_ALL_GATED_PORT = 4003</code> hid 3d behind an &ldquo;Include :4003 (3d)&rdquo; checkbox. Both are gone, together with the
checkbox, its <code>data-update-all-4003</code> hook and the <code>include_4003</code> request parameter. Every entry in
<code>root/config/worktrees.json</code> is now merged with no branch or port special-cased.</p>
<p class="doc-body"><strong>Why.</strong> The exemption was not a safety measure anyone could point at &mdash; the only recorded reason,
&ldquo;Proxmox (:4016) is not a Comserv checkout to merge&rdquo;, was wrong: <code>~/.comserv/worktrees/Proxmox/Comserv</code> is a
comserv2 worktree on branch <code>Proxmox</code> tracking <code>local_main</code>, and its history already contains
<code>Merge branch 'main' into Proxmox</code>. The cost of the exemption was on display: Proxmox sat <strong>108 commits behind
main</strong> with one commit of its own, permanently out of sync with the branch everyone builds from. A skip list in code is how a
branch silently rots.</p>
<p class="doc-body"><strong>What still protects you.</strong> The rules that matter are unchanged and are git&rsquo;s own: a dirty file that
main changes is refused (<code>skipped_local_changes</code> with the file list), a conflict is aborted and the branch left as it was,
nothing is stashed and nothing is forced, the pre-merge sha is recorded per row as the undo point, and a secret/junk guard refusal stays
a <code>blocked</code> row. The one remaining opt-out is an explicit key in <code>update_all_skip</code> inside
<code>worktrees.json</code> &mdash; data in the registry, empty by default, not a constant in the code.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>,
<code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/root/admin/git/index.tt</code>,
<code>Comserv/root/static/js/git-dashboard.js</code>, <code>Comserv/root/Documentation/system/git_worktree_merge_plan.tt</code></p>
<p class="doc-body"><strong>Verified.</strong> <code>perl -Ilib -c</code> on both modules, <code>node --check</code> on the JS, template
re-rendered through TT2 with no <code>include_4003</code> left anywhere. A scratch <code>update_all_from_main</code> run over two fake
worktrees at :4016 and :4003 returned <code>1 fast_forwarded, 1 merged</code> &mdash; no <code>skipped_*</code> rows &mdash; with
&ldquo;Merge branch 'main' into Proxmox&rdquo; as the resulting HEAD. Expected on the real registry: Proxmox will take a large
(108-commit) merge on the next run, so run <strong>Preview</strong> first.</p>
</div>
