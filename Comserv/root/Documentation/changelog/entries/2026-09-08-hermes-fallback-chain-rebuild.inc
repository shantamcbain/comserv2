<div id="2026-09-08-hermes-fallback-chain-rebuild" class="cl-entry">
<h3>2026-09-08 — Rebuild the Hermes fallback chain on verified-capable models</h3>
<p class="doc-body"><strong>What.</strong> The Hermes fallback chain was silently empty, so a
primary-model failure had nowhere to go. Two faults compounded: <code>fallback_providers</code>
in <code>~/.hermes/config.yaml</code> had been persisted as a single-quoted YAML <em>string</em>
rather than a list (the loader only accepts a list/dict, so it resolved to zero entries), and
every entry pointed at <code>opencode-free</code>, which no longer serves scripted clients.</p>
<p class="doc-body"><strong>Why.</strong> A stale exported <code>fallback_providers</code>
environment variable carrying the same mangled string was also present in the shell
environment. Separately, <code>opencode-free</code> now requires an OpenCode client session ID:
a bare client gets Cloudflare <code>403 error code: 1010</code>, a browser user-agent gets
<code>MissingSessionID</code>, and an anonymous bearer gets <code>401 Invalid API key</code>.
Even a correctly parsed chain would therefore have failed on every hop.</p>
<p class="doc-body"><strong>Fix.</strong> Rewrote the chain as nine OpenRouter entries, ordered
by measured capability, and repointed the delegation Coder off
<code>opencode-free</code>. Recorded the probe findings in
<code>.hermes/.model_fallback_chain.txt</code> and the probed-reliability section of
<code>.hermes/models.md</code>.</p>
<p class="doc-body"><strong>Verification.</strong> Candidates were probed with a real
code-generation task rather than a trivial ping, because several models return
<code>200</code> with an empty body. Reliable free models
(<code>ling-3.0-flash-fin</code>, <code>cohere/north-mini-code</code>,
<code>ling-3.0-flash-sante</code>, <code>dots-3-note-preview</code>,
<code>nemotron-3.5-lightning</code>, <code>nemotron-3-ultra-550b</code>) scored 2 of 2;
<code>nemotron-3-super-120b</code> and <code>poolside/laguna-s-2.1</code> were flaky and
demoted; <code>gemma-4-31b-it</code> (persistent 429) and
<code>thinkingmachines/inkling</code> (agentic-harness only) were excluded.</p>
<p class="doc-body"><strong>Files.</strong> <code>~/.hermes/config.yaml</code>,
<code>~/.hermes/.model_fallback_chain.txt</code>, <code>.hermes/models.md</code></p>
</div>
