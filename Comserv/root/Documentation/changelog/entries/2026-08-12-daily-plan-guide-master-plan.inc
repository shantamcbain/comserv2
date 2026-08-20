<div id="2026-08-12-daily-plan-guide-master-plan" class="cl-entry">
<h3>2026-08-12 — Planning tab renamed MASTER PLAN + master plan now displays reliably</h3>
<h2>2026-08-12 — MASTER PLAN tab: rename + reliable display</h2>

<p><strong>What changed:</strong></p>
<ul>
    <li>The CSC-only tab on <code>/planning/daily</code> was relabelled <strong>MASTER PLAN</strong> (was <em>DAILY PLAN GUIDE</em>).</li>
    <li>The tab already <code>INCLUDE</code>s <a href="/Documentation/MASTER_PLAN">Documentation/MASTER_PLAN.tt</a>, so switching to it displays the current master plan, scoped by SiteName.</li>
    <li><strong>Display fix:</strong> the master-plan content is server-rendered into <code>#daily-plan-guide</code>, but it was hidden by
        <code>.tab-content { display: none }</code> until JS added <code>.active</code> via the URL <code>#daily-plan-guide</code> hash.
        Activation ran only on <code>window.load</code>, so a slow/stalled deferred script (or <code>load</code> already fired)
        left the tab blank with no content. Hardened so the plan always shows:
        <ul>
            <li><code>daily-plan.css</code> — <code>#daily-plan-guide</code> is <code>display:block</code> by default (server-rendered, always safe to show); a <code>.tab-hidden</code> helper class hides it when another tab is chosen.</li>
            <li><code>daily-plan-utils.js</code> — <code>switchTab()</code> now toggles <code>.tab-hidden</code> on the guide tab (hidden when another tab is active, shown when selected), and hash-tab activation also runs on <code>DOMContentLoaded</code> + <code>hashchange</code> (not only <code>window.load</code>).</li>
        </ul>
    </li>
</ul>

<p><strong>SiteName scoping:</strong> CSC sees the full cross-site roadmap; other sites see a scoped banner. The tab is CSC-only.</p>

<p><strong>Files touched:</strong></p>
<ul>
    <li><code>root/admin/planning/DailyPlan.tt</code> — tab label <code>DAILY PLAN GUIDE</code> → <code>MASTER PLAN</code>; already <code>INCLUDE</code>s the master plan.</li>
    <li><code>root/static/css/planning/daily-plan.css</code> — guide tab visible by default + <code>.tab-hidden</code> helper.</li>
    <li><code>root/static/js/planning/daily-plan-utils.js</code> — <code>switchTab</code> manages guide visibility; hash activation on <code>DOMContentLoaded</code>/<code>hashchange</code>.</li>
    <li><code>root/Documentation/MASTER_PLAN.tt</code> — back-link label updated to <code>MASTER PLAN</code>.</li>
    <li><code>root/Documentation/DailyPlanSystem.tt</code> — implementation note references renamed tab.</li>
</ul>

<p><strong>Related:</strong></p>
<ul>
    <li><a href="/planning/daily#daily-plan-guide">Daily Plan · MASTER PLAN</a></li>
    <li><a href="/Documentation/MASTER_PLAN">Comserv2 Master Plan</a></li>
</ul>
</div>
