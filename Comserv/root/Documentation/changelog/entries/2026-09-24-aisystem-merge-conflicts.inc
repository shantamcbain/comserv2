<div id="2026-09-24-aisystem-merge-conflicts" class="cl-entry">
<h3>2026-09-24 — AISYSTEM: finish main merge + Hermes panel conflicts</h3>
<p class="doc-body"><strong>What.</strong> Resolved leftover conflict markers in the AI Editor Hermes panel after an in-app <code>main → fix-ai-generate-pipe-model</code> merge. Kept the 720px resizable/detach dashboard (branch) and the ZeroTier :9119 note (main). OpenRouter <code>/ai/generate</code> now copies <code>model</code> and <code>usage</code> onto the response hash. Removed yesterday’s committed <code>.bak</code> copies of AI.pm/Chat.pm/Search.pm. Cleared stale HelpDesk conflict markers that were already on this branch.</p>
<p class="doc-body"><strong>Why.</strong> Conflict markers in <code>editing_widget_popup.tt</code> / <code>hermes-run.js</code> broke the live editor on :4006. The pipe-model OpenRouter path dropped token usage. The <code>.bak</code> files added ~27k junk lines.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/ai2/editor/editing_widget_popup.tt</code>, <code>root/static/js/ai2editor/hermes-run.js</code>, <code>Controller/AI.pm</code>, HelpDesk ticket templates, changelog fragment.</p>
</div>
