<div id="2026-10-27-ai-cannot-publish" class="cl-entry">
<h3>2026-10-27 — AI cannot commit or publish to GitHub</h3>
<p class="doc-body"><strong>What.</strong> Commit and GitHub publish on this repo now require a human. An agent process cannot <code>git commit</code> or <code>git push</code>. The admin git page can publish only <code>main</code> or <code>master</code>, and only from the primary checkout. Creating a branch no longer pushes it. <code>git push --no-verify</code> still hits the SSH gate.</p>
<p class="doc-body"><strong>Why.</strong> A worktree agent pushed <code>git-dev</code> onto GitHub <code>main</code> with this machine's key. Worktrees are tested by a human and merged to main. Only that admin publish goes to GitHub.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/script/git/human_gate.sh</code>, <code>Comserv/script/git/ssh_gate.sh</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>~/.git-hooks/pre-commit</code>, <code>~/.git-hooks/pre-push</code>.</p>
</div>
