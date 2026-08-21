<div id="2026-08-20-ai2-editor-code-read" class="cl-entry">
<h3>2026-08-20 — AI2 Code Editor can read application source</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">The AI2 editor chat (<code>agent_id=code</code>) now injects the open Ace buffer and loads other app files through <code>Model::AI2::CodeRead</code>. Name a path such as <code>lib/Comserv/Model/AI2/Chat.pm</code> or emit <code>[READ_FILE: path]</code> (optional <code>:START-END</code> slice). Allowlisted tops: <code>lib/</code> <code>root/</code> <code>sql/</code> <code>script/</code> <code>t/</code>. Secrets are refused. Privileged roles only. “Can you read the files?” is answered by the server (not Hy3) — chat models otherwise invent “I have no filesystem access.” This is the v2 port of v1 <code>Controller::AI</code> <code>[READ_FILE:]</code> — live path is <code>/ai2/chat</code>.</p>
        </div>
    </div>
</div>
</div>
