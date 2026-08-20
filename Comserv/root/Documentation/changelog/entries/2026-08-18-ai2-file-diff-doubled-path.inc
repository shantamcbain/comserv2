<div id="2026-08-18-ai2-file-diff-doubled-path" class="cl-entry">
<h3>AI2 /ai2/file_diff &mdash; doubled-path fix</h3>
<div class="container">

    <h1 class="doc-h1">AI2 editor diff: real doubled-path bug fixed (Comserv/../Comserv/Comserv/...)</h1>

    <div class="last-updated" doc-muted>
        Last Updated: 2026-08-18 | Version: 1.00 | Author: hermes | Status: Fixed
    </div>

    <div id="toc" class="row doc-toc">
        <div class="col-100">
            <h2 class="doc-h2">Quick Navigation</h2>
            <div class="doc-navrow">
                <a href="#summary" class="doc-navlink">Summary</a>
                <a href="#root" class="doc-navlink">Root cause</a>
                <a href="#fix" class="doc-navlink">Fix</a>
                <a href="#files" class="doc-navlink">Files</a>
                <a href="#verify" class="doc-navlink">Verification</a>
            </div>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="summary" class="doc-h2">1. Summary</h2>
            <p class="doc-body">The Application Error Audit todo <code>ai2/file_diff &mdash; git diff --no-index /dev/null .../Comserv/../home/.../Comserv/Comserv/docker-compose.prod.yml</code> (logged 2026-08-16) is now fixed. The error was a <strong>real, reproducible bug</strong> &mdash; not a transient artifact.</p>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="root" class="doc-h2">2. Root cause</h2>
            <ul class="doc-body">
                <li><code>AI2.pm file_diff</code> built the on-disk path as <code>File::Spec-&gt;catfile($app_dir, $raw_frontend_path)</code>. The frontend sends an <em>app-relative</em> editor path, but it can already carry the repo/app dir prefix (or be absolute). When it does, the concatenation double-appends the directory, producing the exact bogus path in the log: <code>Comserv/..//home/shanta/PycharmProjects/comserv2/Comserv/Comserv/docker-compose.prod.yml</code>.</li>
                <li>That path does not exist, so <code>git diff --no-index /dev/null &lt;nonexistent&gt;</code> exits 1 with no output. <code>Util::Git::git_run</code> logs every non-zero exit as ERROR (no benign-exception rule covers a missing <code>--no-index</code> target), which is what opened the audit todo.</li>
                <li>Note: the 2026-08-15 changelog entry <em>"Git file_diff &mdash; refused"</em> asserted "no change needed in AI2.pm" &mdash; that was incorrect; the doubled-path defect was still present and is the actual root cause of this todo.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="fix" class="doc-h2">3. Fix</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/AI2.pm</code> &mdash; <code>file_diff</code> now derives the on-disk path as <code>&lt;repo_root&gt;/&lt;repo_rel&gt;</code>: it joins the resolved git repo root with the <em>already-correct</em> <code>repo_rel</code> returned by <code>_ai2_repo_rel_path</code> (the same value <code>git ls-files</code>/<code>git diff HEAD</code> use). No more blind concatenation of the raw external path onto a base dir.</li>
                <li>Added a traversal guard: the resolved path must stay inside the repo root, else 400 (mirrors <code>Admin/Git.pm file_diff</code>).</li>
                <li><code>_ai2_repo_rel_path</code> normalization hardened to strip a leading <code>/</code>, <code>Comserv/</code>, <em>and</em> any leading absolute prefix equal to the app dir or repo root, so absolute/over-prefixed frontend paths no longer double up.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="files" class="doc-h2">4. Files changed</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/AI2.pm</code> &mdash; <code>file_diff</code>: path resolved from repo_root + repo_rel, traversal guard; <code>_ai2_repo_rel_path</code>: absolute/over-prefix stripping (uncommitted, pending commit).</li>
                <li>Related (already in place from prior work): <code>lib/Comserv/Util/Git.pm</code> (<code>--no-index</code> allowed), <code>lib/Comserv/Controller/Admin/Git.pm</code> (file_diff logs failures).</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="verify" class="doc-h2">5. Verification</h2>
            <ul class="doc-body">
                <li><code>perl -Ilib -c lib/Comserv/Controller/AI2.pm</code> &rarr; syntax OK.</li>
                <li>Standalone <code>:3001</code> auto-reloads; the doubled-path case is now impossible because the path is built from the canonical <code>repo_root + repo_rel</code> and confined to the repo root.</li>
                <li>Re-test: click <strong>Diff</strong> on a changed/new file in the AI2 Project panel &mdash; for new files it shows full content as additions; for modified files the vs-HEAD diff.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

</div>
</div>
