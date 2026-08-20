<div id="2026-08-12-themeconfig-missing-dir-fix" class="cl-entry">
<h3>ThemeConfig set_site_theme ENOENT Fix - August 12, 2026</h3>
<div class="container">
    <h1 class="doc-h1">ThemeConfig set_site_theme ENOENT Fix &mdash; August 12, 2026</h1>

    <div class="doc-muted last-updated">
        Last Updated: 2026-08-12 |
        Version: 0.01 |
        Author: Hermes Agent |
        Status: Fixed
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="overview" class="doc-h2">1. Issue</h2>
            <p class="doc-body">
                The error-audit system logged repeated <code>ERROR</code> entries from
                <code>Comserv::Model::ThemeConfig::set_site_theme</code> (and the sibling
                writers <code>save_theme</code>, <code>create_theme</code>,
                <code>set_site_favicon</code>, <code>set_domain_favicon</code>):
            </p>
            <div class="doc-codebox">
                <pre><code>Error setting theme 'mcoop' for site 'MCoop':
write_file '/opt/comserv/root/static/config/theme_definitions.json' -
sysopen: No such file or directory</code></pre>
            </div>
            <p class="doc-body">
                This fired on every MCoop index page load because
                <code>Controller/MCoop.pm</code> calls
                <code>set_site_theme($c, "MCoop", "mcoop")</code> on each request.
            </p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="root-cause" class="doc-h2">2. Root Cause</h2>
            <p class="doc-body">
                All five writers persisted JSON via <code>File::Slurp::write_file</code> directly.
                <code>write_file</code> does a bare <code>sysopen()</code> and fails with
                <code>ENOENT</code> when the <em>parent directory</em> does not already exist.
                The dev checkout ships <code>root/static/config/</code>, but the production
                container (<code>/opt/comserv/</code>) did not have that directory present, so
                the write could never succeed.
            </p>
            <p class="doc-body">
                Note that the CSS writer <code>_write_theme_css</code> already created its
                directory with <code>File::Path::make_path</code> &mdash; the JSON writers
                simply never got the equivalent guard.
            </p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="solution" class="doc-h2">3. Solution</h2>
            <p class="doc-body">
                Added a private helper <code>_ensure_parent_dir($c, $file)</code> that
                <code>mkdir -p</code>s the target file's parent before any write, mirroring
                the pattern already used in <code>_write_theme_css</code>. The helper is now
                called at the start of all five JSON writers:
            </p>
            <ul class="doc-body">
                <li><code>set_site_theme</code> (ThemeConfig.pm)</li>
                <li><code>create_theme</code> (ThemeConfig.pm)</li>
                <li><code>save_theme</code> (ThemeConfig.pm)</li>
                <li><code>set_site_favicon</code> (ThemeConfig.pm)</li>
                <li><code>set_domain_favicon</code> (ThemeConfig.pm)</li>
            </ul>
            <p class="doc-body">
                The directory is now guaranteed to exist regardless of deployment state, so
                the write succeeds on both dev and prod.
            </p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="files" class="doc-h2">4. Files Modified</h2>
            <ul class="doc-body">
                <li><code>Comserv/lib/Comserv/Model/ThemeConfig.pm</code> &mdash; added
                    <code>_ensure_parent_dir</code> and guarded all five <code>write_file</code> calls.</li>
            </ul>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="testing" class="doc-h2">5. Verification</h2>
            <ul class="doc-body">
                <li><code>perl -c lib/Comserv/Model/ThemeConfig.pm</code> &rarr; syntax OK.</li>
                <li>Logic review: <code>_ensure_parent_dir</code> returns the existing dir when
                    present (no-op on dev), and creates it when missing (resolves prod ENOENT).</li>
                <li>Sibling call paths (<code>Admin/Theme.pm</code>, <code>ThemeAdmin.pm</code>,
                    <code>MCoop.pm</code>, <code>HostingSignup.pm</code>,
                    <code>SiteProvisioning.pm</code>) are covered through the centralized model fix.</li>
            </ul>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="see-also" class="doc-h2">6. See Also</h2>
            <div class="doc-success">
                <ul class="doc-body">
                    <li><a href="/Documentation/ThemeConfig" class="doc-link">Theme Configuration</a></li>
                    <li><a href="/Documentation/CssThemes" class="doc-link">CSS Theme System &mdash; Admin Guide</a></li>
                </ul>
            </div>
        </div>
    </div>
</div>
</div>
