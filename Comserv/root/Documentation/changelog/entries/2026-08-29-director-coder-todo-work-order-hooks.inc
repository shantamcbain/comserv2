<div id="2026-08-29-director-coder-todo-work-order-hooks" class="cl-entry">
<h3>2026-08-29 — Director+Coder work-order hooks on error todos and Start</h3>
<p class="doc-body"><strong>What.</strong> New Application Error Audit todos now seed <code>description</code> with a structured work-order stub (ROOT/DO/DO NOT/ACCEPT) before the raw log body. Starting a todo whose description lacks a work order appends an append-only <code>WORK_ORDER_NEEDED</code> note to <code>comments</code> (never wipes comments).</p>
<p class="doc-body"><strong>Why.</strong> Hermes Director+Coder process (todo #2350): free/cheap Coders must not re-plan from bare fingerprints; every todo touch should leave or surface an executable work order. Error-audit rows and empty Start targets were the main gaps.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Logging.pm</code>, <code>Comserv/lib/Comserv/Util/TodoLog.pm</code> (<code>toggle_start</code> open path). Hermes skill <code>comserv2-hermes-director-coder</code>.</p>
</div>
