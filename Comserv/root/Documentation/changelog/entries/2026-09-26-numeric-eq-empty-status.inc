<div id="2026-09-26-numeric-eq-empty-status" class="cl-entry">
<h3>2026-09-26 — Quiet empty/string status numeric warnings</h3>
<p class="doc-body"><strong>What.</strong> Todo ranking and project-done checks coerce status with a digit check before <code>==</code>. Shop cart badge only adds integer quantities. Empty status and values like <code>Not-Started</code> no longer spam <code>Argument "" isn't numeric</code> on <code>/planning/daily</code>.</p>
<p class="doc-body"><strong>Why.</strong> Live todos mix numeric status (2, 3) with strings (<code>Not-Started</code>, blank). Perl <code>==</code> warns on every row.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/TodoRanking.pm</code>, <code>Util/ProjectDependencies.pm</code>, <code>Navigation/TopDropListShop.tt</code></p>
</div>
