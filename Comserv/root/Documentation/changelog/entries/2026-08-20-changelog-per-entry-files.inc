<div id="2026-08-20-changelog-per-entry-files" class="cl-entry">
<h3>2026-08-20 — Changelog notes are per-file fragments (stop merge conflicts)</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">A single <code>CHANGELOG.tt</code> that every branch prepends (TOC top + file tail) conflicted on almost every main↔worktree merge. Notes now live as <code>root/Documentation/changelog/entries/YYYY-MM-DD-slug.inc</code>. <code>/Documentation/CHANGELOG</code> is a generated reader. Adding a note is adding a file — git does not collide. Fragments use <code>.inc</code> so they are not extra Documentation routes (scanner only indexes <code>.tt</code>/<code>.md</code>).</p>
            <p class="doc-body">Files: <code>lib/Comserv/Util/Changelog.pm</code>, <code>lib/Comserv/Controller/Documentation.pm</code>, <code>root/Documentation/changelog/CHANGELOG.tt</code>, <code>t/util_changelog.t</code>.</p>
        </div>
    </div>
</div>
</div>
