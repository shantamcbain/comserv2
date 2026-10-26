<div id="2026-10-21-dockerha-merge-secret-guard" class="cl-entry">
<h3>2026-10-21 — DockerHA merge of main no longer stuck on an already-tracked key</h3>
<p class="doc-body"><strong>What.</strong> Merging main into DockerHA left MERGE_HEAD set and logged a git error whose only text was "Created autostash". The secret-guard hook refused <code>Comserv/config/.mail_encryption_key</code>, which is already on main, and also flagged small images and JSON as keys.</p>
<p class="doc-body"><strong>Why.</strong> A worktree cannot take main while the hook treats a blob already on a parent as a new secret, and a failed pre-merge-commit leaves the merge in progress. The dashboard then logged that as ERROR.</p>
<p class="doc-body"><strong>Files.</strong> <code>~/.git-hooks/secret-guard.sh</code>, <code>Comserv/script/git/secret_guard.sh</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code></p>
</div>
