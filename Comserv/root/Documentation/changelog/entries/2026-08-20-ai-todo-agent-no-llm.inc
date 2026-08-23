<div id="2026-08-20-ai-todo-agent-no-llm" class="cl-entry">
<h3>2026-08-20 — In-chat Todo agent: create todos without the picker model</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body">Free OpenRouter models (e.g. Nemotron) answered “add a todo” by inventing a fake Add box on <code>/ai/widget</code>. The in-chat Todo agent now runs at the start of <code>AI2::Chat::process</code> (the path every widget send takes) and writes a real todo: current SiteName, matched project (or ask to create one), <code>scheduled_date</code> for planning. Cost for a clear request is $0 — the dropdown model is not used. Full agent runner / sub-agents stay on AutonomousAgentsPlan (#268), which must absorb this job rather than rebuild it.</p>
        </div>
    </div>
</div>
</div>
