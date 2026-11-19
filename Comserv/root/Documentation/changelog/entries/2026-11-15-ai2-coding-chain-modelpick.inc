<div id="2026-11-15-ai2-coding-chain-modelpick" class="cl-entry">
<h3>2026-11-15 — AI editor and code agents follow the Hermes model chain</h3>
<p class="doc-body"><strong>What.</strong> With Super Grok locked by the daily allowance guard,
<code>ModelPick</code> picked <code>ollama|qwen2.5vl:3b</code> — a 3B vision model — to write a
coding plan for <code>agent=programming phase=plan</code> (log: <em>"pick - Chose
ollama|qwen2.5vl:3b (score:light) groups sg=0 or=14 ol=4"</em>). Two faults: the generic score
ignored provider order and model capability, and the routing classifier's LLM verdict was allowed
to <em>downgrade</em> complexity, so a guard-locked day reported <code>complexity=low</code>.</p>
<p class="doc-body"><strong>Why.</strong> <code>ModelPick::pick</code> scored whatever happened to be
live and free, so a small local model tied or won for light tasks, and paid OpenRouter models were
excluded outright by <code>available_groups</code> — which also excluded the very model Hermes itself
had switched to (<code>particle-ai/particle-1</code>). Nothing checked capability for coding work.</p>
<p class="doc-body"><strong>Solution.</strong> Coding agents (<code>programming</code>, <code>coding</code>,
<code>code</code>, <code>editor</code>, <code>gitfix*</code>, <code>analyze</code>) now walk the Hermes
chain in order, read at request time from <code>~/.hermes/config.yaml</code>
(<code>model.default</code> + <code>fallback_providers</code>) and
<code>~/.hermes/guard_model_switch.json</code> (<code>from</code> = SuperGrok allotment head,
<code>to</code> = current model) — no hardcoded copy, so a guard switch is followed automatically.
Each hop must be live (OpenRouter id present in the current catalog, Ollama name present in
<code>/api/tags</code>, SuperGrok only when the guard is unlocked) and every hop is logged with its
skip reason. If no hop is live, the catalog is used with a <em>capability floor</em>: vision-only and
sub-7B models are excluded for coding, and if nothing else exists the weak model is still used but
with a visible notice (surfaced through the existing <code>fallback_reason</code> note) instead of
silently. The routing classifier may now only <em>raise</em> rule-based complexity, never lower it,
and the SuperGrok head is <code>grok-4.7</code> — never <code>grok-build</code>/glm/Relace. A
hand-picked model is untouched: <code>select_model</code> returns before <code>pick</code> for a real
user pick.</p>
<p class="doc-body"><strong>Follow-up (same day, live check failed).</strong> The first version wired the chain into
<code>ModelPick::pick</code>, but a real editor Send still landed on
<code>ollama|qwen2.5vl:3b</code>. Two more faults: (a) <strong>context drift</strong> — the request's
agent+phase reached <code>select_model</code> once and were then lost, because
<code>Router::dispatch_chat</code> re-selects with only <code>requested_model</code>/<code>can_select</code>
(the pick logged <code>agent=(none) phase=(none)</code>) and <code>GitFix</code> re-selects on its own;
(b) <strong>the classifier still ran</strong> — <code>is_editor_agent</code> used a hardcoded regex
without <code>gitfix-*</code>, so a gitfix-analysis request paid
<code>ollama_classify_chat=125486ms</code> and the editor read-phase shortcut returned
<code>north-mini</code> before the chain was ever consulted. Fixed by stashing
<code>ai2_agent_ctx</code> (agent/phase/surface) once in <code>ai2_chat</code> and inheriting it in
<code>select_model</code> when a hop omits them; <code>dispatch_chat</code> now forwards
<code>agent_id</code>/<code>phase</code>/<code>no_llm_classify</code> and <code>GitFix</code> passes its coding context;
the LLM classifier is skipped entirely for coding/editor agents and otherwise capped at a hard
5s <code>alarm</code>; and the coding chain now runs <em>before</em> the editor phase pins. One
definition, <code>ModelPick::is_editor_agent</code>, is used by the controller, Router and ChatIntent so
<code>gitfix-*</code> cannot drift again. Regression cover:
<code>t/ai2_editor_coding_chain_path.t</code> drives the real
<code>select_model → coding_pick → hermes_chain</code> path with the drift hop (no agent_id passed).</p>
<p class="doc-body"><strong>Files.</strong>
<code>lib/Comserv/Model/AI2/ModelPick.pm</code> (new
<code>hermes_chain</code>, <code>live_model_set</code>, <code>pick_from_chain</code>,
<code>coding_pick</code>, <code>is_coding_agent</code>, <code>is_editor_agent</code>,
<code>is_weak_for_coding</code>; pick log now names agent/phase/skips),
<code>lib/Comserv/Model/AI2/Router.pm</code> (request-context inheritance, chain before phase pins,
coding-agent classify skip + 5s alarm cap, complexity floor, notice propagation, SuperGrok head
grok-4.7), <code>lib/Comserv/Controller/AI2.pm</code> (stashes <code>ai2_agent_ctx</code>,
unified editor-agent test), <code>lib/Comserv/Model/AI2/ChatIntent.pm</code>,
<code>lib/Comserv/Model/AI2/GitFix.pm</code>,
<code>t/ai2_modelpick_coding_chain.t</code> (25 tests),
<code>t/ai2_editor_coding_chain_path.t</code> (15 tests, real call path).</p>
</div>
