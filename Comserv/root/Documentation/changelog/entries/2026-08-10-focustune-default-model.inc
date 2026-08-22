<div id="2026-08-10-focustune-default-model" class="cl-entry">
<h3>AI Focus-Tune — Use catalog default model, not hardcoded phi4:14b</h3>
&#91;% IF c.session.debug_mode == 1 %&#93;&#91;% PageVersion %&#93;&#91;% END %&#93;







<div class="changelog-entry">
    <header class="changelog-header">
        <h1>AI Focus-Tune default model — de-hardcoded</h1>
        <div class="changelog-meta">
            <span class="date">August 10, 2026</span>
            <span class="author">by shanta</span>
            <span class="type">Bug fix / daily-plan AI Focus-Tune</span>
        </div>
    </header>

    <section class="changelog-summary">
        <p>
            The daily-plan <strong>AI Focus-Tune</strong> (the 🤖 AI: Tune / ⚖ Compare
            buttons on Today&rsquo;s Focus Queue &mdash; &ldquo;ask AI to check the accuracy of
            the top 20&rdquo;) hardcoded <code>phi4:14b</code> (a localhost Ollama model) as
            its default in three client-side spots and as the server fallback. On a box where
            Ollama is unreachable (or where the user should be on a free/paid OpenRouter model),
            the tune would silently run on the wrong model. The default is now derived from the
            <strong>same shared catalog</strong> every other AI surface uses.
        </p>
    </section>

    <section class="changelog-details">
        <h2>What changed</h2>
        <ul>
            <li><code>Controller::Api::_focus_default_model($c)</code> (new) returns
                <code>ModelCatalog-&gt;default_for(page =&gt; 'chat')</code> &mdash; the
                free OpenRouter default for guests/members, or the pinned coding model for
                privileged users &mdash; in <code>provider|model</code> form. Falls back to the
                first catalog entry, then to a hard safe default only if the catalog is empty.</li>
            <li><code>GET /api/focus/models</code> now returns a <code>default</code> field
                (the catalog default) alongside <code>models</code>.</li>
            <li><code>api_focus_top5</code> uses the catalog default instead of the literal
                <code>phi4:14b</code> when no model is explicitly selected.</li>
            <li><code>daily-plan-utils.js</code>: the three <code>phi4:14b</code> literals
                (the <code>_aiTuneTargets</code> fallback, the model-popup init, and the
                <code>.catch</code> fallback) now read <code>_aiTuneDefault</code>, populated
                from the server&rsquo;s <code>default</code> field. No client-side model
                hardcode remains.</li>
        </ul>

        <h2>Verified</h2>
        <p>
            Live <code>GET /api/focus/models</code> returns
            <code>default: openrouter|nvidia/nemotron-3-nano-30b-a3b:free</code> and the model
            picker now pre-selects that default. <code>perl -c</code> on Api.pm and
            <code>node --check</code> on daily-plan-utils.js both pass.
        </p>

        <h2>Files changed</h2>
        <ul>
            <li><code>lib/Comserv/Controller/Api.pm</code> &mdash; add <code>_focus_default_model</code>; use it in <code>api_focus_models</code> + <code>api_focus_top5</code></li>
            <li><code>root/static/js/planning/daily-plan-utils.js</code> &mdash; drive default from server <code>default</code> field, remove <code>phi4:14b</code> literals</li>
            <li><code>root/Documentation/changelog/2026-08-10-focustune-default-model.tt</code> &mdash; this entry</li>
        </ul>
    </section>
</div>
</div>
