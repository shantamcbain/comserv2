<div id="2026-08-11-auto-db-info-cache-and-poll-guard" class="cl-entry">
<h3>Per-request CPU storm &amp;mdash; static DB info cached + chat polling loops made idempotent</h3>
&#91;% IF c.session.debug_mode == 1 %&#93;&#91;% PageVersion %&#93;&#91;% END %&#93;







<div class="changelog-entry">
    <header class="changelog-header">
        <h1>Per-request CPU storm &mdash; static DB info cached, polling loops idempotent</h1>
        <div class="changelog-meta">
            <span class="date">August 11, 2026</span>
            <span class="author">by shanta</span>
            <span class="type">Performance / Bug Fix</span>
        </div>
    </header>

    <section class="changelog-summary">
        <p>
            The workstation CPU spiked to ~99% (load 11.6, 20 starman workers CPU-spinning in
            <code>state=R</code>). Two coupled causes, both now fixed:
        </p>
        <ul>
            <li><strong>Server:</strong> <code>Controller/Root.pm::auto</code> re-derived the
                static DB-connection info (<code>get_connection_info</code> &mdash; a fixed config
                hash) and re-ran <code>get_all_sites</code> (a full DB query + 17 log lines) on
                <em>every</em> request, even though the DB location is known and never changes per
                request. As the user put it: &ldquo;why is the code repeatedly scanning for db when
                it already knows the only location it exists.&rdquo;</li>
            <li><strong>Client:</strong> <code>root/static/js/ai-chat/support.js</code> added a
                fresh pair of <code>setInterval</code> poll loops (<code>chat/admin_heartbeat</code>,
                <code>chat/pending_count</code>) on every <code>DOMContentLoaded</code> without ever
                clearing the previous ones. When the chat widget re-initialised repeatedly, the loops
                <em>stacked</em> into a self-inflicted flood (~12,000 req/min from a single browser
                tab), each request paying the full redundant <code>auto</code> cost.</li>
        </ul>
    </section>

    <section class="changelog-details">
        <h2>Why multiple tabs are fine, but stacking is not</h2>
        <p>
            Separate browser tabs are separate clients/sessions; each legitimately runs one poll loop
            &mdash; that is correct and was never the problem. The defect was <em>one page
            accumulating many loops</em> because the script kept adding intervals without removing
            old ones. On a multi-domain production host the same stacking would multiply across
            re-initialisations and collapse the box quickly, which is exactly why it had to be fixed
            at the source rather than just closing the tab.
        </p>

        <h2>Fix</h2>
        <ul>
            <li><code>lib/Comserv/Controller/Root.pm</code> &mdash; caches the resolved
                DB-connection list + host per worker (5-minute TTL), following the existing
                <code>$_remotedb_status</code> precedent already in the file. Cache hits skip all
                model/DB work in <code>auto</code>. The data is identical for every domain a process
                serves, so this is correct on a multi-domain production host.</li>
            <li><code>root/static/js/ai-chat/support.js</code> &mdash; extracted the admin notifier
                start into <code>_scheduleAdminNotifier()</code>, which clears any existing timers
                before (re)starting. Re-running the script can never stack additional loops. One poll
                loop per page, exactly as intended (initial 2s poll + 30s pending + 20s heartbeat).</li>
        </ul>

        <h2>Verified</h2>
        <ul>
            <li><code>perl -c</code> clean on <code>Controller/Root.pm</code>.</li>
            <li><code>node --check</code> clean on <code>ai-chat/support.js</code>.</li>
            <li>Standalone app (3001) auto-reloads <code>.pm</code>/<code>.js</code>; a fresh page
                load now runs one poll loop.</li>
        </ul>

        <h2>Files changed</h2>
        <ul>
            <li><code>lib/Comserv/Controller/Root.pm</code> &mdash; per-worker DB-connection cache + guarded <code>auto</code> gather</li>
            <li><code>root/static/js/ai-chat/support.js</code> &mdash; idempotent <code>_scheduleAdminNotifier()</code></li>
            <li><code>root/Documentation/changelog/2026-08-11-auto-db-info-cache-and-poll-guard.tt</code> &mdash; this entry</li>
            <li><code>root/Documentation/changelog/CHANGELOG.tt</code> &mdash; [Unreleased] bullet cross-linked here</li>
        </ul>

        <h2>Related</h2>
        <ul>
            <li><a href="&#91;% c.uri_for('/Documentation/changelog/2026-08-10-ai2-providers-hashref-guard') %&#93;">AI2 Providers &mdash; guard against malformed catalog elements</a></li>
        </ul>
    </section>
</div>
</div>
