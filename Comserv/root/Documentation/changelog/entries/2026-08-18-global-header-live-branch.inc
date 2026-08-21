<div id="2026-08-18-global-header-live-branch" class="cl-entry">
<h3>Global header &mdash; show LIVE branch/commit (no more stale &quot;main&quot; from version.json)</h3>
<div class="container">

    <h1 class="doc-h1">Global server-info header now reports the real checkout branch</h1>

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
                <a href="#verify" class="doc-navlink">Verification</a>
            </div>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="summary" class="doc-h2">1. Summary</h2>
            <p class="doc-body">The global server-info bar (every admin/debug page, <code>root/pagetop.tt</code>) showed <code>Git: main@&lt;sha&gt;+local</code> derived from the build-time <code>version.json</code>. When the same built code is served from a branch worktree (e.g. <code>git-dev</code> on :4004, or any develop server), the header kept advertising <code>main</code> &mdash; misleading a developer into thinking they were working on <code>main</code> and risking commits to the wrong branch. The header now reflects the <strong>live</strong> checkout branch and short commit.</p>
            <p class="doc-backtop"><a href="#toc" class="doc-link">&uarr; Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="root" class="doc-h2">2. Root cause</h2>
            <ul class="doc-body">
                <li><code>Root.pm auto()</code> read <code>version.json</code> (baked at image build time, <code>branch: main</code>) and stashed it verbatim as <code>app_version</code>; <code>pagetop.tt</code> rendered <code>app_version.branch</code> / <code>app_version.commit</code>. The build stamp never updates when the code is later run from a different branch worktree.</li>
                <li>The git dashboard's own &quot;Current branch&quot; card was already correct (it calls <code>Comserv::Util::Git-&gt;get_current_branch</code> against the resolved repo), so the two surfaces disagreed &mdash; the header lied, the dashboard told the truth.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">&uarr; Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="fix" class="doc-h2">3. Fix</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Util/Git.pm</code> &mdash; added <code>current_branch_and_commit($c)</code> returning <code>{ branch, commit }</code> from the live checkout (reuses the validated <code>repo_path</code> resolution the dashboard already uses, so the two can't drift).</li>
                <li><code>lib/Comserv/Controller/Root.pm</code> &mdash; after loading <code>app_version</code>, overlays <code>branch</code>/<code>commit</code> with the live values. <code>build_date</code> and <code>build_host</code> keep their baked values. The <code>+local</code> suffix is preserved when the live short sha differs from the baked one, so the &quot;locally modified vs baked&quot; signal survives the overlay.</li>
                <li>pagetop.tt needs no change &mdash; it still reads <code>app_version</code>.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">&uarr; Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="verify" class="doc-h2">4. Verification</h2>
            <ul class="doc-body">
                <li><code>perl -Ilib -c lib/Comserv/Util/Git.pm</code> &rarr; syntax OK; <code>perl -Ilib -c lib/Comserv/Controller/Root.pm</code> &rarr; syntax OK.</li>
                <li>Exercised <code>current_branch_and_commit</code> against the :4004 git-dev worktree checkout via a minimal <code>$c</code> mirroring <code>repo_path</code> resolution &rarr; returned <code>branch=git-dev, commit=288ed668</code>. With the overlay logic the header will render <code>Git: git-dev@288ed668+local</code> instead of <code>main@fbbc501c+local</code>.</li>
                <li>Any develop server now advertises its real branch in the header with no restart (the dev server auto-reloads the changed <code>.pm</code>).</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">&uarr; Back to Top</a></p>
        </div>
    </div>

</div>
</div>
</div>
