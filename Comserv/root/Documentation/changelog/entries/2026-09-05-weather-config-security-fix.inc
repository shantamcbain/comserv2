<div id="2026-09-05-weather-config-security-fix" class="cl-entry">
<h3>2026-09-05 — Weather Configuration Security Fix</h3>
<p class="doc-body"><strong>What.</strong> Guests could access /Weather/configuration and the API key was pre-filled (visible in HTML source) even with type=password.</p>
<p class="doc-body"><strong>Why.</strong> Weak role check (allowed members + used $c->user_exists) and raw api_key stashed+output in template value=.</p>
<p class="doc-body"><strong>Fix.</strong> Strict admin-only via session roles. Never include real api_key in template response (use has_api_key flag). Preserve existing key on save if blank submitted. Updated form UX to indicate when key is set.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Weather.pm</code>, <code>Comserv/root/Weather/configuration.tt</code></p>
</div>