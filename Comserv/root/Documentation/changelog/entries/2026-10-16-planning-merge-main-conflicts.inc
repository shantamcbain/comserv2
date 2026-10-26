<div id="2026-10-16-planning-merge-main-conflicts" class="cl-entry">
<h3>2026-10-16 — planning merge of main left conflict markers; server would not compile</h3>
<p class="doc-body"><strong>What.</strong> Merging main into planning stopped on conflict markers in AI2 Chat, Router, GitFix, the editor chat script, and two HelpDesk templates. Chat.pm aborted Catalyst startup on :4005.</p>
<p class="doc-body"><strong>Why.</strong> Planning’s ModelPick / user-pick path and main’s quota classification, editor phase chain, and guest-ticket fields both had to stay. Markers are gone; Android source stays untracked, matching main’s repo split.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code>, <code>Router.pm</code>, <code>GitFix.pm</code>, <code>Comserv/root/static/js/ai2editor/chat.js</code>, <code>Comserv/root/CSC/HelpDesk/new_ticket.tt</code>, <code>ticket_view.tt</code></p>
</div>
