<div id="2026-08-19-supergrok-source" class="cl-entry">
<h3>2026-08-19 — SuperGrok prepaid models as a portable catalog source</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">The in-app picker can now list SuperGrok models (<code>grok-4.6</code> first) using the same prepaid subscription Hermes uses. Credential resolution is <strong>container-portable</strong>: <code>/run/secrets/supergrok_oauth</code>, mounted <code>/home/comserv/.comserv/secrets/supergrok_oauth</code>, <code>COMSERV_SECRETS_DIR</code>, env <code>SUPERGROK_OAUTH_TOKEN</code>/<code>XAI_OAUTH_TOKEN</code>, then Ency <code>UserApiKeys</code> service <code>supergrok</code>/<code>xai-oauth</code>. Host <code>~/.hermes/auth.json</code> is a last-resort local-dev fallback only.</p>
            <p class="doc-body">Sync a workstation token into the shared secrets dir (already bind-mounted into every compose service): <code>perl script/sync_supergrok_token.pl</code>. Files: <code>lib/Comserv/Model/AI2/Provider/Grok.pm</code>, <code>Router.pm</code>, <code>Util/ModelCatalog.pm</code>, <code>root/ai/model_select.tt</code>, <code>root/static/js/ai-chat/model-select.js</code>, <code>t/provider_grok_supergrok.t</code>. Tracked as <a href="/todo/details?record_id=2202" class="doc-link">#2202</a> under <a href="/project/details?project_id=282" class="doc-link">#282 AISYS-W1</a>.</p>
        </div>
    </div>
</div>
</div>
