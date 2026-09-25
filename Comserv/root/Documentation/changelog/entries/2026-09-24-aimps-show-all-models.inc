<div id="2026-09-24-aimps-show-all-models" class="cl-entry">
<h3>2026-09-24 — Chat model picker hides premium unless Show all</h3>
<p class="doc-body"><strong>What.</strong> Shared <code>model-select.js</code> shortlists the live catalog (drop premium &gt; $5/1M, cap chat at 24, coding surfaces keep coding-class). A <code>Show all models</code> checkbox restores the full list (saved in localStorage). Fixes the widget using the unfiltered <code>ComservConfig.models</code> dump.</p>
<p class="doc-body"><strong>Why.</strong> AIMPS #2024 / #2025 — 387 OpenRouter rows overwhelmed the picker even after server shortlists.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/ai-chat/model-select.js</code></p>
</div>
