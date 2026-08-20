<div id="2026-08-10-ai-model-catalog-single-source" class="cl-entry">
<h3>AI Model Catalog &amp;mdash; Single Source of Truth &amp;amp; Chat Widget Repair</h3>
&#91;% IF c.session.debug_mode == 1 %&#93;&#91;% PageVersion %&#93;&#91;% END %&#93;







<div class="changelog-entry">
    <header class="changelog-header">
        <h1>AI Model Catalog &mdash; Single Source of Truth &amp; Chat Widget Repair</h1>
        <div class="changelog-meta">
            <span class="date">August 10, 2026</span>
            <span class="author">by shanta</span>
            <span class="type">Bug Fix / Refactor</span>
        </div>
    </header>

    <section class="changelog-summary">
        <h2>Summary</h2>
        <p>
            Repaired the AI chat regression that emptied the &ldquo;Chat with AI&rdquo; widget
            and removed the model list from every page, then consolidated model
            selection into one server-side source of truth,
            <code>Comserv::Util::ModelCatalog</code>. Model dropdowns are now
            server-rendered from a single partial, filtered to real chat models,
            cost-labelled, and default to a free model instead of silently loading
            the workstation GPU.
        </p>
    </section>

    <section class="changelog-details">
        <h2>Root causes fixed</h2>
        <ul>
            <li><strong>Lowercase <code>Process</code> in Template Toolkit.</strong> All three
                call sites invoked the shared dropdown partial with a lowercase
                <code>Process</code>. TT directives are UPPERCASE; the lowercase form
                parses as an undefined variable and renders nothing, leaving an empty
                <code>&lt;select&gt;</code> on <code>/ai</code>, <code>/ai2</code> and the
                floating widget.</li>
            <li><strong>Popup bypassed the shared loader.</strong> <code>/ai/widget</code> is
                rendered by <code>widget.tt</code> through a standalone
                <code>Template-&gt;new</code> with no Catalyst context, so it never received
                the catalog stash or the cache-buster; it served a frozen
                <code>?v=1</code> and an empty widget.</li>
            <li><strong>Malformed partial.</strong> <code>ai/model_select.tt</code> leaked its own
                comment text into the page and its grouping loop produced no options.</li>
        </ul>

        <h2>New: Comserv::Util::ModelCatalog</h2>
        <ul>
            <li>Single source of truth for the AI model list across every surface:
                floating widget, <code>/ai/widget</code> popup, <code>/ai</code>,
                <code>/ai2</code>, the AI2 editor and the git dashboard.</li>
            <li>Built once per process from the v2 Router
                (<code>Model::AI2-&gt;get_available_models</code>) &mdash; the same source
                <code>/ai2/providers</code> uses &mdash; and cached with a 600&nbsp;second TTL.</li>
            <li><code>prime()</code> lets <code>Controller::AI2::providers</code> populate the
                cache from a catalog it already built, avoiding a second provider
                round-trip.</li>
            <li>Failure is non-destructive: a failed rebuild keeps the last good cache
                and retries in 30&nbsp;seconds rather than blanking the dropdown.</li>
            <li>Strips Router sentinels (<code>ollama_empty</code>,
                <code>ollama_unreachable</code>, <code>*_unconfigured</code>) so status markers
                are never offered as selectable models.</li>
        </ul>

        <h2>Cost-aware presentation</h2>
        <ul>
            <li>Each entry carries <code>free</code>, <code>local</code> and <code>paid</code> flags.</li>
            <li>Free models sort first inside their provider group and are labelled
                &ldquo;&mdash;&nbsp;free&rdquo;; Ollama models are labelled &ldquo;&mdash;&nbsp;local&rdquo;.</li>
            <li>Non-chat families (embeddings, rerankers, image, audio, video,
                moderation) are filtered out: 414 catalog entries render as 397 options.</li>
            <li><code>default_for()</code> pre-selects a free OpenRouter model for guests and
                ordinary members, and the pinned coding model for privileged users on a
                coding surface. Previously the browser selected the first option
                alphabetically, which silently routed every guest to a local Ollama
                model and loaded the already-saturated workstation GPU.</li>
        </ul>

        <h2>Follow-up fix &mdash; wrong provider used and mislabelled</h2>
        <p>
            After the catalog repair, selecting a free OpenRouter model still produced
            an answer labelled &ldquo;Ollama (Local): tencent/hy3&rdquo;. Four separate
            defects, all fixed:
        </p>
        <ul>
            <li><strong>Auto-tiering hijacked external selections.</strong>
                <code>autoSelectProvider()</code> only ever returns local Ollama tiers
                (<code>state.modelTiers</code> contains nothing else). Because the
                server-rendered default does not set <code>userModelOverride</code>,
                auto-tiering ran and replaced the chosen OpenRouter model with an Ollama
                one. It now returns the current selection unchanged whenever that
                selection is not Ollama.</li>
            <li><strong>Hardcoded <code>'ollama'</code> default.</strong>
                <code>state.selectedProvider</code> was initialised to
                <code>'ollama'</code> and never synced from the server-rendered
                <code>&lt;select&gt;</code>, so the request went local while the dropdown
                displayed something else. It now starts empty and
                <code>mountProviderSelect()</code> adopts the server default.</li>
            <li><strong>Labels assumed &ldquo;not Grok therefore Ollama&rdquo;.</strong> Both
                the change handler and the response handler built the status string that
                way, so every OpenRouter model was announced as Ollama. Replaced with a
                shared <code>describeModel()</code> helper in
                <code>ai-chat/model-select.js</code> that derives the provider from the
                <code>provider|model</code> value.</li>
            <li><strong>Popup never loaded the shared module.</strong>
                <code>widget.tt</code> omitted <code>ai-chat/model-select.js</code>, so
                <code>describeModel()</code> fell back to a crude inline version and the
                backend's generic bucket name <code>external</code> leaked into the UI.
                The script is now included, and <code>describeModel()</code> maps
                <code>external</code> with a slash-bearing slug to OpenRouter.</li>
        </ul>
        <p>
            Verified live in the popup: status now reads
            &ldquo;OpenRouter: nvidia/nemotron-3-nano-30b-a3b:free&rdquo; with a real
            model response and no console errors.
        </p>

        <h2>Files changed</h2>
        <ul>
            <li><code>lib/Comserv/Util/ModelCatalog.pm</code> &mdash; new</li>
            <li><code>lib/Comserv/Controller/Root.pm</code> &mdash; stash catalog + default from the util</li>
            <li><code>lib/Comserv/Controller/AI.pm</code> &mdash; widget passes catalog, default and <code>css_v</code> explicitly</li>
            <li><code>lib/Comserv/Controller/AI2.pm</code> &mdash; primes the shared cache</li>
            <li><code>root/ai/model_select.tt</code> &mdash; rewritten shared partial</li>
            <li><code>root/ai/widget.tt</code> &mdash; catalog global, server-rendered select, dynamic cache-buster</li>
            <li><code>root/js_load.tt</code>, <code>root/ai/index.tt</code>, <code>root/ai2/index.tt</code> &mdash; <code>PROCESS</code> fix</li>
        </ul>

        <h2>Follow-up plan</h2>
        <p>
            Remaining work &mdash; per-model pricing, premium filtering, page and role
            scoped shortlists, usage telemetry, and the standing v2-migration and
            documentation-sync rules &mdash; is tracked in
            <a href="&#91;% c.uri_for('/Documentation/AIModelPresentationPlan') %&#93;">AI Model Presentation &amp; Selection</a>
            (project 252, phases 253&ndash;257, todos 2020&ndash;2035).
        </p>
    </section>
</div>
</div>
