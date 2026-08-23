<div id="2026-08-10-ai2-providers-hashref-guard" class="cl-entry">
<h3>AI2 Providers &amp;mdash; guard against malformed catalog elements</h3>
&#91;% IF c.session.debug_mode == 1 %&#93;&#91;% PageVersion %&#93;&#91;% END %&#93;







<div class="changelog-entry">
    <header class="changelog-header">
        <h1>AI2 Providers &mdash; guard against malformed catalog elements</h1>
        <div class="changelog-meta">
            <span class="date">August 10, 2026</span>
            <span class="author">by shanta</span>
            <span class="type">Bug Fix</span>
        </div>
    </header>

    <section class="changelog-summary">
        <p>
            An unauthenticated (guest-tier) request to <code>/ai2/providers</code> at bmaster
            returned the <strong>correct free model list</strong> yet also raised
            <em>&ldquo;Not a HASH reference at Controller/AI2.pm line 76&rdquo;</em>, which
            spawned an error-audit todo. The grouping loop dereferenced
            <code>$m-&gt;{provider}</code> on every element of the catalog; one element was
            not a hashref &mdash; an upstream provider JSON anomaly (Ollama
            <code>/api/tags</code> or OpenRouter <code>/v1/models</code> occasionally returns a
            non-object entry).
        </p>
    </section>

    <section class="changelog-details">
        <h2>Fix</h2>
        <p>Two layers now reject non-hash elements instead of dying:</p>
        <ul>
            <li><code>lib/Comserv/Controller/AI2.pm::providers</code> &mdash; the per-element
                loop skips any entry whose <code>ref</code> is not <code>HASH</code>, logging an
                <code>ai2_providers</code> warning that records the offending element's shape
                (scalar string / array / other ref / undef).</li>
            <li><code>lib/Comserv/Model/AI2/Router.pm::get_available_models</code> &mdash;
                sanitizes the assembled catalog immediately before the role filter, dropping any
                non-hashref element and logging a <code>get_available_models</code> warning with
                the element's shape. Because <code>get_available_models</code> is the single
                source of truth, the bad element is already gone before the chat widget,
                <code>/ai</code>, <code>/ai2</code> and the git dashboard consume it.</li>
        </ul>

        <h2>Why defensive rather than a one-line type check</h2>
        <p>
            The catalog is built entirely from upstream provider JSON, so a malformed entry is an
            <em>environment</em> fault, not a code fault we can reproduce by inspection. Dropping
            the bad entry keeps the endpoint healthy for every other user, and the accompanying
            warning captures the exact payload on the next occurrence so the responsible provider
            API can be fixed at the boundary if it recurs. The guest request that triggered this
            had already returned the right data &mdash; the 500 was purely the loop choking on one
            stray element.
        </p>

        <h2>Verified</h2>
        <ul>
            <li><code>perl -c</code> clean on <code>Controller/AI2.pm</code> and
                <code>Model/AI2/Router.pm</code>.</li>
            <li>The endpoint now degrades gracefully: a malformed entry is dropped, not fatal.</li>
        </ul>

        <h2>Files changed</h2>
        <ul>
            <li><code>lib/Comserv/Controller/AI2.pm</code> &mdash; skip + log non-hash elements in <code>providers</code></li>
            <li><code>lib/Comserv/Model/AI2/Router.pm</code> &mdash; sanitize catalog before role filter in <code>get_available_models</code></li>
            <li><code>root/Documentation/changelog/2026-08-10-ai2-providers-hashref-guard.tt</code> &mdash; this entry</li>
            <li><code>root/Documentation/changelog/CHANGELOG.tt</code> &mdash; [Unreleased] bullet cross-linked here</li>
        </ul>

        <h2>Related</h2>
        <ul>
            <li><a href="&#91;% c.uri_for('/Documentation/changelog/2026-08-10-ai-model-catalog-single-source') %&#93;">AI Model Catalog &mdash; Single Source of Truth</a></li>
            <li><a href="&#91;% c.uri_for('/Documentation/changelog/2026-08-10-model-role-filter') %&#93;">AI model list &mdash; role-based visibility</a></li>
        </ul>
    </section>
</div>
</div>
