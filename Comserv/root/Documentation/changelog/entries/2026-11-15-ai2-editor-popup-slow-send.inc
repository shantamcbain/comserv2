<div id="2026-11-15-ai2-editor-popup-slow-send" class="cl-entry">
<h3>2026-11-15 — AI2 code editor popup: 154s load and a dead Send button</h3>
<p class="doc-body"><strong>What.</strong> GET <code>/ai2/editing_widget_popup</code> took 154 seconds and, once
open, clicking <em>Send</em> produced no request at all (no <code>POST /ai2/chat</code>), while the file
passed in <code>?file=</code> never appeared in the code panel — the panel reported that
<code>ai2editor/core.js</code> had not loaded.</p>
<p class="doc-body"><strong>Why — the popup had no JavaScript at all.</strong> Every
<code>/static/…</code> request returned <strong>404</strong>, including <code>base.css</code>: the
<code>:4006</code> server (PID started 00:55) was launched with its working directory at
<code>/home/shanta</code>, and <code>Plugin::Static::Simple</code> resolves a relative
<code>include_path</code> entry against the process CWD — so <code>'root'</code> meant
<code>/home/shanta/root</code> (nonexistent). No JS meant no Send handler, no file load and no model
list. Fixed by adding a CWD-proof absolute entry derived from <code>FindBin $Bin</code>
(<code>&lt;app&gt;/script</code>) ahead of <code>'root'</code> in <code>lib/Comserv.pm</code>. Config is
read at app setup, so this one needs a server restart to take effect.
<br><em>Second cause (masked by the first):</em> <code>ai2editor/chat.js</code> called
<code>initModelSelect()</code> <em>before</em> binding the Send handler, so any throw during model-list
wiring left Send unbound; and the phase-AutoClarify gate demanded repro steps for <em>any</em> prompt
under 200 characters on the default analyze phase, so an ordinary brief was swallowed into Clarify.
<br><em>Slow load:</em> <code>editing_widget_popup</code> resolved the model by calling
<code>$router-&gt;select_best_model($c)</code> inline, which runs <code>classify_prompt_for_routing</code>
and its <em>optional local Ollama LLM classifier</em> — a blocking <code>/api/chat</code> generate
(120s warm / 480s cold UA timeout, no budget). At 16:14:30Z the log shows
<code>ollama_resolve_host</code>, then 152s of silence, then <code>select_best_model</code> logging
<code>complexity=low use_sg=1</code> — the classifier's own verdict, proving it ran and ate the stall
(it picked <code>ollama|qwen2.5vl:3b</code>, the only model matching its "small" regex).</p>
<p class="doc-body"><strong>Files.</strong>
<code>lib/Comserv.pm</code> (CWD-proof absolute static <code>include_path</code> — restart required),
<code>lib/Comserv/Controller/AI2.pm</code> (popup serves the per-session cached model, resolves at most
once inside a hard 3s <code>alarm</code> with <code>no_llm_classify</code>, falls back to the head of the
coding chain, logs <code>ai2_editor_model</code> elapsed ms),
<code>lib/Comserv/Model/AI2/Router.pm</code> (per-stage timing logged as <code>ai2_classify_timing</code>;
new <code>no_llm_classify</code> opt-out with a warning comment on the blocking generate),
<code>root/static/js/ai2editor/chat.js</code> (Send/input bound first, every other init step isolated in
<code>guardStep</code>, failures reported in the chat panel and status line, repro-step gap now requires a
short bug-shaped ask, clarify status says nothing was sent yet),
<code>root/ai2/editor/editing_widget_popup.tt</code> (file-load errors surfaced in both the status line and the
chat panel, bounded retry instead of an endless silent loop),
<code>t/ai2_editor_chat_wiring.test.js</code> (node harness: Send is wired even when the model list throws, and
a click posts exactly one <code>/ai2/chat</code>; 5 of its 7 checks fail against the pre-fix file).</p>
</div>
