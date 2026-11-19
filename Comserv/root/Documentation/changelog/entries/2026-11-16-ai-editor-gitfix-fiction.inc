<div id="2026-11-16-ai-editor-gitfix-fiction" class="cl-entry">
<h3>2026-11-16 — AI editor stopped answering with a made-up git diagnosis</h3>
<p class="doc-body"><strong>What.</strong> A question in the AI editor came back as a fictional diagnosis of a git commit path rejection. The editor had attached <code>Chat.pm</code>. One line in that file matches <code>git … commits … paths</code>. <code>GitFix</code> treated that as the user's error, called a model with no validator source, and returned the story as the chat reply.</p>
<p class="doc-body"><strong>Why.</strong> The interceptor has to match the user's ask, not attached source, and only the real flash string <code>Rejected unsafe or unknown path</code>. The reply now quotes <code>Admin/Git.pm</code> <code>_validate_paths</code>. No model call.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/GitFix.pm</code>, <code>lib/Comserv/Controller/AI2.pm</code>, <code>t/ai2_gitfix_no_fiction.t</code>, <code>t/ai_router_dispatch_usage.t</code></p>
</div>
