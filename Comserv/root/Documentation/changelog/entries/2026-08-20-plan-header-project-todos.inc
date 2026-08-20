<div id="2026-08-20-plan-header-project-todos" class="cl-entry">
<h3>2026-08-20 — Plan header: Open project + View todos</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-20 | Version: 1.00 | Tracked in project: <a href="/project/details?project_id=272" class="doc-link">#272 (DRYER-INT)</a>.</p>
            <p class="doc-body">Every plan that INCLUDEs the shared doc header now shows <strong>Open project</strong> and <strong>View todos</strong> immediately under the title when META has <code>project_id</code>. Dryer import playbook is the first consumer; the same header is used by <code>DocumentationTtTemplate</code> and other plans. Unregistered <code>.tt</code> docs now stash META <code>project_id</code>/<code>project_code</code> so the buttons actually appear.</p>
            <p class="doc-body">Files: <code>root/admin/documentation/_doc_header.tt</code>, <code>lib/Comserv/Controller/Documentation.pm</code>, <code>root/Documentation/DocumentationTtTemplate.tt</code>, <code>root/static/css/components/documentation.css</code>.</p>
        </div>
    </div>
</div>
</div>
