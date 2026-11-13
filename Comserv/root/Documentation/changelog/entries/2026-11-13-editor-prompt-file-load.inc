<div id="2026-11-13-editor-prompt-file-load" class="cl-entry">
<h3>2026-11-13 — Editor review briefs load the files they name</h3>
<p class="doc-body"><strong>What.</strong> A review brief that names <code>lib/</code>, <code>root/</code>, <code>script/</code>, or <code>t/</code> paths now loads those paths even when the prompt also says review and file. A how-to URL containing <code>/ai2/</code> no longer forces the four AI2 sources.</p>
<p class="doc-body"><strong>Why.</strong> Todo 2735. The HealthKitchen brief named Recipe.pm, but <code>isAboutAiEditor</code> matched <code>/ai2/</code> in the instructions URL and <code>wantEval</code> skipped the path scan, so only AI2.pm, Chat.pm, CodeRead.pm, and Router.pm were attached.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/static/js/ai2editor/chat.js</code>.</p>
</div>
