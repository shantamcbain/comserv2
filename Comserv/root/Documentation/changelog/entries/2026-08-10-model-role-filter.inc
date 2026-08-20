<div id="2026-08-10-model-role-filter" class="cl-entry">
<h3>AI Model List — Role-based visibility (guests see free tier only)</h3>
&#91;% IF c.session.debug_mode == 1 %&#93;&#91;% PageVersion %&#93;&#91;% END %&#93;







<div class="changelog-entry">
    <header class="changelog-header">
        <h1>AI model list — role-based visibility</h1>
        <div class="changelog-meta">
            <span class="date">August 10, 2026</span>
            <span class="author">by shanta</span>
            <span class="type">Feature / AIMPS Phase 3 (#255)</span>
        </div>
    </header>

    <section class="changelog-summary">
        <p>
            The shared model catalog (<code>Comserv::Util::ModelCatalog</code>) previously
            returned the <strong>entire</strong> list &mdash; every paid OpenRouter model plus
            Grok &mdash; to every caller, including not-logged-in users (the floating
            &ldquo;Chat with AI&rdquo; widget is visible to guests). A guest therefore saw the
            same 400+ model list an admin sees. Now the catalog is <strong>role-filtered</strong>
            at the single source of truth, so each role gets its own shortlist (AIMPS Phase 3
            &mdash; role-scoped shortlists).
        </p>
    </section>

    <section class="changelog-details">
        <h2>Visibility tiers</h2>
        <ul>
            <li><strong>guest / anonymous</strong> &mdash; free tier only: free OpenRouter
                models (<code>:free</code> slugs) + Ollama local. No paid models, no Grok.</li>
            <li><strong>member</strong> (logged in, non-privileged) &mdash; free + cheap + mid.
                Premium models (dearer side &gt; $5 / 1M tokens) and Grok are excluded.</li>
            <li><strong>privileged</strong> (admin / developer / editor) &mdash; the full catalog.</li>
        </ul>
        <p>
            The unfiltered list stays in the process cache; filtering is applied per request in
            <code>catalog()</code> / <code>catalog_json()</code> (cheap, ~414 entries). This means
            <code>window.ComservConfig.models</code> (the global the widget, <code>/ai</code>,
            <code>/ai2</code> and the git dashboard all render from) is already role-filtered, so
            no per-surface JS change was needed.
        </p>

        <h2>Verified</h2>
        <p>
            Live unauthenticated request to <code>/ai/widget</code> now returns
            <strong>19 models</strong> (5 Ollama local + 14 free OpenRouter), with
            <strong>0 paid</strong> and <strong>0 Grok</strong> visible &mdash; down from the full
            414-model admin list. Privileged sessions still receive the full catalog.
            <code>perl -c</code> on ModelCatalog passes.
        </p>

        <h2>Files changed</h2>
        <ul>
            <li><code>lib/Comserv/Util/ModelCatalog.pm</code> &mdash; add <code>_role_tier</code> +
                <code>_filter_for_role</code>; <code>catalog</code> / <code>catalog_json</code> now
                return the role-filtered list</li>
            <li><code>lib/Comserv/Model/AI2/Router.pm</code> &mdash; apply the SAME role filter
                at <code>get_available_models</code> (the single source of truth), so every
                consumer (ModelCatalog, <code>/ai2/providers</code>, widget, <code>/ai</code>,
                git dashboard) is filtered with NO per-list re-implementation. This is the
                &ldquo;high in the tree&rdquo; placement the user asked for.</li>
            <li><code>root/Documentation/changelog/2026-08-10-model-role-filter.tt</code> &mdash; this entry</li>
        </ul>
    </section>
</div>
</div>
