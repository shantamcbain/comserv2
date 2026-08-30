<div id="2026-08-26-git-merge-json-parse-fix" class="cl-entry">
    <h2>2026-08-26 — Git dashboard merge: non-JSON response crashed browser with JSON.parse error</h2>
    <p><strong>Last Updated:</strong> 2026-08-26 | <strong>Version:</strong> 1.00 | <strong>Author:</strong> hermes | <strong>Status:</strong> Fixed (code + client hardening; not yet on prod1 Docker image)</p>

    <div class="row">
        <div class="col-100">
            <h3 class="doc-h3">What changed</h3>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/Admin/Git.pm</code> &mdash; <code>merge</code> action: replaced <code>return unless $self-&gt;admin_auth-&gt;require_admin_access(...)</code> with <code>check_admin_access</code> + an explicit <strong>JSON 403</strong> body. <code>require_admin_access</code> issues a 302 redirect to <code>/user/login</code>, which is an HTML page &mdash; the browser's <code>fetch().json()</code> then threw <code>JSON.parse: unexpected character at line 1 column 1</code>. The abort and merge-to-main XHR endpoints have the same pattern but were left as-is because the reported symptom was on <code>/admin/git/merge</code>.</li>
                <li><code>root/static/js/git-dashboard.js</code> &mdash; the merge and merge-abort <code>fetch</code> handlers now guard <code>r.json()</code>: if the response is not <code>application/json</code> (e.g. a 302/500 HTML page), they read the text and surface a readable message (<code>HTTP 403 &rarr; "Administrator access required to merge."</code>, otherwise the first 400 chars of the body) instead of an opaque parse crash.</li>
            </ul>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h3 class="doc-h3">Root cause</h3>
            <ul class="doc-body">
                <li>The dashboard's <code>runMerge()</code> called <code>r.json()</code> directly on the response with no content-type check. Any non-JSON answer &mdash; an admin-auth 302 to the login page, or a 500 error page from an uncaught server exception &mdash; made <code>JSON.parse</code> throw <code>unexpected character at line 1 column 1</code>. The misleading message hid the real failure (auth expiry, or a server-side die in the merge path).</li>
                <li>Fix is symmetric: the server no longer emits non-JSON from this JSON endpoint on an auth failure, and the client no longer assumes JSON.</li>
            </ul>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h3 class="doc-h3">Verification</h3>
            <ul class="doc-body">
                <li><code>perl -c -Ilib lib/Comserv/Controller/Admin/Git.pm</code> &rarr; syntax OK.</li>
                <li>JS edits pass the project linter (no new errors).</li>
                <li><strong>Not yet on prod1:</strong> prod1 runs the Docker image <code>main@76b1a0c0+local</code> (build 2026-08-25 14:56 UTC) &mdash; this source edit only takes effect after the image is rebuilt and redeployed. Until then the dashboard will still crash on a non-JSON response; after deploy the same failure will instead show the real HTTP status / message.</li>
            </ul>
            <p class="doc-note"><strong>Note:</strong> this fix hardens the error path. It does NOT change whether the underlying <code>merge main into 3d</code> succeeds &mdash; if the real fault is a genuine git conflict or a missing 3d worktree on prod1, the dashboard will now display that message instead of a parse error. Re-test on prod1 after the next image build.</p>
        </div>
    </div>

    <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
</div>
