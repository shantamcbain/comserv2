<div id="2026-10-22-ai-editor-wysiwyg" class="cl-entry">
<h3>2026-10-22 — AI Editor visual (WYSIWYG) mode</h3>
<p class="doc-body"><strong>What.</strong> The AI Editor’s Editor menu now switches HTML and template files between Ace source and a visual editor (bold, headings, lists, links). TT tags, scripts, and styles stay locked chips. Save and chat still use the Ace buffer.</p>
<p class="doc-body"><strong>Why.</strong> The Rich Text choice was a stub, so “edit with AI” could only change source. Visual edit is for page content; code files stay in Ace.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/ai2/editor/editing_widget_popup.tt</code>, <code>Comserv/root/static/js/ai2editor/adapters/richtext.js</code>, <code>Comserv/root/static/js/ai2editor/core.js</code>, <code>Comserv/root/static/js/ai2editor/chat.js</code></p>
</div>
