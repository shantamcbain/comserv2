<div id="2026-08-13-daily-plan-remove-duplicate-action-card" class="cl-entry">
<h3>2026-08-13 — Removed duplicate action bar on /planning/daily; added End Day + Open Logs to the card</h3>
<h2>2026-08-13 — Removed duplicate action bar; added End Day + Open Logs</h2>

<p><strong>What changed:</strong></p>
<ul>
    <li><code>/planning/daily</code> rendered <strong>two</strong> identical action bars:
        <ul>
            <li>a top-level <code>.daily-action-card</code> ("Day Controls") above the tab bar in <code>DailyPlan.tt</code>; and</li>
            <li>a second <code>.ActionBar</code> inside the <strong>Daily Priorities</strong> tab, in <code>_today_work_tab.tt</code>.</li>
        </ul>
    </li>
    <li>The second (in-tab) bar was the duplicate. It is hidden on this page via <code>&#91;% INCLUDE 'admin/planning/_today_work_tab.tt' hide_action_bar = 1 %&#93;</code>. The top "Day Controls" card stays as the only action bar on <code>/planning/daily</code>.</li>
    <li><strong>Added two buttons to the top card:</strong>
        <ul>
            <li><strong>End Day</strong> (<code>data-action="end-day"</code>) — always present (no longer only shown when a log is already open).</li>
            <li><strong>Open Logs</strong> (<code>data-action="toggle-log-panel"</code>) — the alert icon button; it only appears when there is still an open/unclosed log (the original "a log was missed" alert).</li>
        </ul>
    </li>
    <li>There are now <strong>two distinct log buttons</strong> on the card (the earlier version had removed the permanent one, causing the glitch):
        <ul>
            <li><strong>Logs</strong> — a permanent link to <code>/log</code>, always present so the user can always check what is still open today.</li>
            <li><strong>Open Logs</strong> (icon) — the conditional alert described above.</li>
        </ul>
    </li>
    <li>The card now always shows: Add Todo, All Todos, <strong>Logs</strong>, <strong>Start Day</strong>, <strong>End Day</strong> (admin: Triage Stale, Reschedule); the <strong>Open Logs</strong> icon button appears only when a log is still open, alerting the user that a log was missed.</li>
    <li>The shared inner bar in <code>_today_work_tab.tt</code> is wrapped in <code>&#91;% IF hide_action_bar != 1 %&#93; ... &#91;% END %&#93;</code>, so it still renders normally on the other two pages that include it without the flag (<code>DailyPriorities.tt</code>, <code>DailyPlan.legacy.tt</code>).</li>
</ul>

<p><strong>Files touched:</strong></p>
<ul>
    <li><code>root/admin/planning/DailyPlan.tt</code> — pass <code>hide_action_bar = 1</code> to the include; add End Day + Open Logs to the top card (always visible).</li>
    <li><code>root/admin/planning/_today_work_tab.tt</code> — wrap the action bar in <code>&#91;% IF hide_action_bar != 1 %&#93;</code> (no button changes otherwise).</li>
</ul>

<p><strong>Related:</strong></p>
<ul>
    <li><a href="/planning/daily">Daily Planning</a></li>
    <li><a href="/planning/daily-priorities">Daily Priorities</a></li>
</ul>
</div>
