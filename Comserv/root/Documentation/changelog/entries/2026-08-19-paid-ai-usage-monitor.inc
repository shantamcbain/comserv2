<div id="2026-08-19-paid-ai-usage-monitor" class="cl-entry">
<h3>2026-08-19 — SuperGrok 80% alert + daily OpenRouter/xAI usage log</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Tracked: <a href="/todo/details?record_id=2203" class="doc-link">#2203</a> / project <a href="/project/details?project_id=267" class="doc-link">#267 AGENTS</a>.</p>
            <p class="doc-body">Paid AI spend was only half-tracked: v1 chat wrote <code>ai_usage_logs</code>, v2 AI2 chat did not. SuperGrok had no quota alert. OpenRouter credits were never pulled from their API.</p>
            <ul class="doc-body">
                <li>Every AI2 chat turn now logs provider, model, tokens, estimated cost, success/fail.</li>
                <li>SuperGrok is routed through the Grok client (it was falling through to Ollama).</li>
                <li>OpenRouter live credits from <code>GET /api/v1/auth/key</code>.</li>
                <li>SuperGrok 80% of monthly allowance (config <code>root/config/ai_usage.json</code>) writes a system <code>[Error]</code> once per day so Application Error Audit pops it. Banner on <code>/ai/usage</code>.</li>
                <li>Daily-by-model table on <code>/ai/usage</code> so we can see which models ran and what they cost.</li>
            </ul>
            <p class="doc-body">Assumption: xAI does not publish remaining SuperGrok OAuth quota. 80% is tracked month spend vs <code>supergrok_monthly_limit_usd</code> (default $30) or request count vs <code>supergrok_monthly_request_limit</code> (default 400), whichever is higher. Edit the JSON if the real SuperGrok allowance is different.</p>
            <p class="doc-body"><strong>Providers are not interchangeable.</strong> SuperGrok = prepaid OAuth (no auto-fill, no remaining-quota API). xAI grok = pay-per-token with auto-fill ON. OpenRouter = live credits, no auto-fill (HTTP 402 when empty). When SuperGrok or OpenRouter is exhausted, every v2 path (<code>Chat::process</code> and <code>Router::dispatch_chat</code>, including FocusTune) falls back to a live OpenRouter <code>:free</code> model then the first chat-capable Ollama tag. xAI credit errors do not trigger that fallback.</p>
            <p class="doc-body"><code>/ai</code> admin chrome: the Ollama host IP was sitting in the top bar like the model picker. The labelled <strong>Model</strong> dropdown is now the main control (role-filtered catalog: Ollama, SuperGrok prepaid, xAI auto-fill, OpenRouter). Host stays in the DOM for page-mode JS but is visually secondary. <code>📊 Usage</code> links to <code>/ai/usage</code>.</p>
        </div>
    </div>
</div>
</div>
