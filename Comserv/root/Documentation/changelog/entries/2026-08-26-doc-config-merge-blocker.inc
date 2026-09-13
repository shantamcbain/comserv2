<div id="2026-08-26-doc-config-merge-blocker" class="cl-entry">
<h3>2026-08-26 — Stop tracking runtime doc-config overlay (merge-blocker fix)</h3>
<p class="doc-body"><strong>What.</strong> <code>Comserv/root/session/documentation_config/DocumentationConfig.json</code> (and <code>scan_state.json</code>) were tracked in git, but the app rewrites them on every scan/save via <code>_atomic_write_json</code>. That ~13,000-line generated blob made every <code>main &lt;-&gt; Documentation</code> merge collide. They are now gitignored and removed from the index in <strong>both</strong> the Documentation worktree and the main/PycharmProjects checkout. The shipped seed (<code>root/Documentation/config/*.json</code>) stays tracked.</p>
<p class="doc-body"><strong>Why.</strong> Eliminates the recurring git-merge conflict / loop on the doc catalog. The file is recreated by the app (<code>make_path</code>) on first write, so ignoring it is safe.</p>
<p class="doc-body"><strong>Verify.</strong> <code>git merge --no-ff main</code> now reports "Automatic merge went well" with zero conflicts. Full permanent cure (DB move) tracked as work item — see <code>/Documentation/doc_config_db_move_plan</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>.gitignore</code>, both checkouts' index. App code unchanged.</p>
</div>
