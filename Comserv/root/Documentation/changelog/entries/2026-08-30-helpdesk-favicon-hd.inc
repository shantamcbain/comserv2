<div id="2026-08-30-helpdesk-favicon-hd" class="cl-entry">
<h3>2026-08-30 — HelpDesk favicon: green HD badge on branch, port, pages, public domain</h3>
<p class="doc-body"><strong>What.</strong> Restored the HelpDesk tab icon (green <strong>HD</strong> badge formerly used on zenflow port <code>:4013</code> and <code>/favicon/helpdesk</code>) for the live helpdesk worktree on <code>:4009</code>, all <code>/HelpDesk/*</code> pages, and public host <code>helpdesk.computersystemconsulting.ca</code>.</p>
<p class="doc-body"><strong>Why.</strong> Port/label maps still called <code>:4009</code> “Pt” (PointSystem) and registry fallback used “He” from the branch name, so the worktree did not show the HelpDesk identity.</p>
<p class="doc-body"><strong>How.</strong>
<ul>
<li><code>Root.pm</code> <code>_port_label</code>: registry branch <code>helpdesk</code> → HD; named map <code>4009</code>/<code>4013</code> → HD; other worktree ports aligned with current registry.</li>
<li><code>branch_favicon</code>: <code>helpdesk</code> detaches to <code>/favicon/helpdesk</code>; other branches render short label text.</li>
<li><code>HelpDesk.pm</code> <code>auto</code>: sets <code>page_favicon</code> to <code>/favicon/helpdesk</code>.</li>
<li><code>theme_definitions.json</code>: domain map for helpdesk hosts + <code>page_favicons</code> regex for HelpDesk paths; static SVG at <code>static/images/favicons/helpdesk.svg</code>.</li>
</ul>
</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Root.pm</code>, <code>…/HelpDesk.pm</code>, <code>Comserv/root/static/config/theme_definitions.json</code>, <code>Comserv/root/static/images/favicons/helpdesk.svg</code></p>
</div>
