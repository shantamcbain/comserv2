<div id="2026-11-06-aisystem-apptime-page-ai-finish" class="cl-entry">
<h3>2026-11-06 — AppTime zone calls and page-AI assist are finished in the working tree</h3>
<p class="doc-body"><strong>What.</strong> The aisystem AppTime slice now reads the operator zone from <code>Comserv::Util::AppTime</code> instead of a hardcoded Pacific name. The last two call sites were <code>Model::AI2::ModelScorecard</code> and <code>Model::AI2::TaskTracker</code>. Page-AI assist no longer ships an inline style or script: the rules are in <code>theme-overrides.css</code>, and <code>page-ai-assist.js</code> loads from <code>js_load.tt</code> on <code>/pages/create</code> and <code>/pages/edit</code>.</p>
<p class="doc-body"><strong>Why.</strong> Those two slices were the unfinished code blocking the next plan changes. Runtime JSON, including the unmerged <code>ai_model_chains.json</code> index, is still not feature code and must not be committed to make the tree look clean.</p>
<p class="doc-body"><strong>Files.</strong> Todo <a href="/todo/details?record_id=2384">#2384</a>. Not committed in this step.</p>
</div>
