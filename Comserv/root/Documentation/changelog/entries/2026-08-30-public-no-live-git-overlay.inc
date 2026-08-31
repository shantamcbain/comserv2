<div id="2026-08-30-public-no-live-git-overlay" class="cl-entry">
<h3>2026-08-30 — Public/bot requests no longer run live git overlay</h3>
<p class="doc-body"><strong>What.</strong> <code>Root::auto</code> only calls <code>current_branch_and_commit</code> (live <code>git branch --show-current</code>) when the session is admin or debug_mode. Anonymous marketplace/crawler hits no longer spawn git or create <code>git_run</code> ERROR audit todos. The server-info bar (including Git branch@sha) was already template-gated to admin/debug.</p>
<p class="doc-body"><strong>Why.</strong> Bots were not accessing <code>/admin/git</code>. Every public page still ran live git for the header overlay; on production1 Docker that failed exit 128 and the request IP (bot) appeared on the audit todo — looking like “bots see git” when the git dashboard remains admin-only.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Root.pm</code>. Related earlier: <code>Comserv/Util/Git.pm</code> no-.git skip + benign show-current (needs prod image).</p>
</div>
