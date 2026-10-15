<div id="2026-09-08-xai-quota-vs-auth-403" class="cl-entry">
<h3>2026-09-08 — Distinguish x.AI quota 403 from an expired login (no more bogus re-auth)</h3>
<p class="doc-body"><strong>What.</strong> x.AI returns <code>HTTP 403</code> for two unrelated
conditions: a rejected credential (<code>unauthenticated:bad-credentials</code>) and a spent
subscription (<code>personal-team-blocked:spending-limit</code>). The provider collapsed both
into "SuperGrok/xAI login expired or invalid — re-auth", so users were told to re-auth a valid
token, and the Router's credit-exhaustion matcher never fired, meaning the free-model fallback
chain never engaged and the turn simply dead-ended.</p>
<p class="doc-body"><strong>Why.</strong> Symptom was a chat turn that failed with a re-auth
instruction while the OAuth token was actually valid; the real cause was an exhausted quota.
Three call sites misreported it: <code>Provider::Grok</code> (user-facing string and the
<code>auth_failed</code> flag), <code>Router::_credits_exhausted</code> (fallback decision),
and <code>Controller::Admin::Git</code> (commit-message draft error shown in the UI).</p>
<p class="doc-body"><strong>Fix.</strong> <code>_sanitize_provider_error</code> now checks for
spending-limit markers first (with a negative lookahead for genuine credential failures).
The <code>auth_failed</code> flag is no longer set for a quota 403.
<code>_credits_exhausted</code> treats a spending-limit error as "this hop is down" so
<code>chat_with_fallback</code> falls through to the next model.
<code>Git.pm</code> gained a matching quota branch ahead of its re-auth branch.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Model/AI2/Provider/Grok.pm</code>,
<code>Comserv/lib/Comserv/Model/AI2/Router.pm</code>,
<code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code></p>
<p class="doc-body"><strong>Verification.</strong> <code>perl -c</code> clean on all three.
A 13-assertion harness exercised the real subroutines: quota 403 yields the quota message and
falls through; auth 403 yields the re-auth message and does not; 503 and connection failures
still fall through; unrelated errors are unchanged.</p>
</div>
