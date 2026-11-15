<div id="2026-11-13-ency-fill-search-first" class="cl-entry">
<h3>2026-11-13 — Add Herb searches sources before it fills the form</h3>
<p class="doc-body"><strong>What.</strong> The encyclopedia form fill searches sites for the name, then compiles those sources into the form's JSON fields. The compile step is not SuperGrok. That hop was taking about 200 seconds, and the page aborted at 120 seconds, so the fields never arrived.</p>
<p class="doc-body"><strong>Why.</strong> The old path searched, then filled the app format. The new path asked SuperGrok with web search off, and the browser threw the answer away.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/Chat.pm</code>, <code>Controller/AI2.pm</code>, <code>Util/AI/ModelChains.pm</code>, <code>root/ENCY/partials/AiFormFill.tt</code></p>
</div>
