<div id="2026-10-23-git-dev-inotify-poll-fallback" class="cl-entry">
<h3>2026-10-23 — git-dev -r starts when inotify instances are full</h3>
<p class="doc-body"><strong>What.</strong> If <code>Linux::Inotify2-&gt;new</code> fails (fs.inotify.max_user_instances, seen at 126/128), <code>comserv_server.pl -r</code> uses the File::ChangeNotify poll watcher instead of dying.</p>
<p class="doc-body"><strong>Why.</strong> The die ("Too many open files") aborted the restarter before :4004 listened. The open-files ulimit was already 524288; the cap is inotify instances, which raise_nofile cannot raise.</p>
<p class="doc-body"><strong>Files.</strong> <code>script/comserv_server.pl</code></p>
</div>
