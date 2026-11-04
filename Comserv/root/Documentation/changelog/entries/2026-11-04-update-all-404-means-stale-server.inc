<div id="2026-11-04-update-all-404-means-stale-server" class="cl-entry">
<h3>2026-11-04 — Update-all 404 now says "stale server", not "signed out"</h3>
<p class="doc-body"><strong>What.</strong> The Update-all-from-main card's fetch guard reported every non-JSON reply as <em>"you are probably signed out"</em>. A 404 from <code>POST /admin/git/update_all_from_main</code> now reports that the action is not loaded in the running server and names the fix: restart that worktree's dev server.</p>
<p class="doc-body"><strong>Why.</strong> The card markup and <code>git-dashboard.js</code> are read from disk per request, but Catalyst compiles controller actions at startup. A worktree that just merged <code>main</code> therefore renders the new card against a server that predates the endpoint — every click 404s. The old message blamed the admin session and hid the real cause.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/static/js/git-dashboard.js</code>.</p>
</div>
