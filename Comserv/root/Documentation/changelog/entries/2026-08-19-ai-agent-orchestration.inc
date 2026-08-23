<div id="2026-08-19-ai-agent-orchestration" class="cl-entry">
<h3>2026-08-19 — AI Agent Orchestration + Notification Recovery</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-19 | Version: 0.1 | Tracked in project: <a href="/project/details?project_id=267" class="doc-link">#267 (AGENTS)</a>. Folded here from a standalone dated changelog file (policy: single CHANGELOG.tt).</p>
            <h4 class="doc-h3">What changed</h4>
            <ul class="doc-body">
                <li><strong>New plan <a href="/Documentation/AIAgentOrchestrationPlan" class="doc-link">AIAgentOrchestrationPlan</a></strong> (proj #267 AGENTS, sub-project of the Autonomous Agents plan). Defines: (a) the two agent classes — branch-context <code>.hermes.md</code> files (done, focused) vs specialized recurring agents; (b) operational agents (Email agent = missing input; Secretary agent = DB-eval → VoIP critical call, text/voice/browser, multi-model Ollama/OpenRouter/Grok); (c) in-app agents (HelpDesk/Beekeeping/Ency) blocked until their todos exist; (d) principles + phasing + project tracking.</li>
                <li><strong>Notification regression recorded.</strong> Historically in-app + system + email worked; today ONLY email works. Logged as a separate blocking todo (not folded into agent work).</li>
                <li><strong>VoIP config page planned.</strong> Successor to the old Perl4 &quot;call a page&quot; feature — a new page where the user registers their own VoIP number so the Secretary can call them.</li>
                <li><strong>Cross-links added.</strong> MASTER_PLAN Planning nav + reference list now link the new plan; AutonomousAgentsPlan (parent #267) gained a &quot;Child plan&quot; link.</li>
            </ul>
            <p class="doc-body"><strong>Open item (not done that session):</strong> the SECRETARY-AGENT sub-project under #267 was not persisted via the API. Create it in the app project UI, then stamp its ID into the plan. The plan references it as &quot;SECRETARY-AGENT, child of #267&quot; until then.</p>
            <p class="doc-body">Related: <a href="/Documentation/AIAgentOrchestrationPlan" class="doc-link">AI Agent Orchestration</a>, <a href="/Documentation/AutonomousAgentsPlan" class="doc-link">Autonomous Agents Plan</a>, <a href="/Documentation/HermesBranchContextPlan" class="doc-link">Hermes Branch Context</a>.</p>
        </div>
    </div>
</div>
</div>
