<div id="2026-08-19-ai-index-tt-parse-retry" class="cl-entry">
<h3>2026-08-19 — ai/index.tt unexpected-EOF: retry truncated TT compile</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">Application Error Audit todo <a href="/todo/details?record_id=2147" class="doc-link">#2147</a> (site 3d, <code>workstation-prod-local:5000</code>, 114 hits) is <code>Couldn't render template "ai/index.tt ... line 34: unexpected end of input"</code>. The on-disk template is complete (1111 lines) and compiles. The live :5000 compose bind-mounts <code>./Comserv</code> over <code>/opt/comserv</code>, so a request that compiles the file mid-save reads a half-written copy. Earlier diagnosis closed this as non-reproducible; it kept firing.</p>
            <p class="doc-body"><strong>Fix:</strong> <code>Comserv::View::TT::render</code> retries once after 150ms + TT cache reset when the error is this truncation class. Recovered races log <code>warning</code>; a still-broken template logs <code>error</code> and rethrows (audit trail kept). No change to <code>root/ai/index.tt</code> (already over the 1000-line soft target; source is valid).</p>
            <p class="doc-body">Files: <code>lib/Comserv/View/TT.pm</code>, <code>t/view_TT.t</code>. Verify: <code>prove -l t/view_TT.t</code>.</p>
        </div>
    </div>
</div>
</div>
