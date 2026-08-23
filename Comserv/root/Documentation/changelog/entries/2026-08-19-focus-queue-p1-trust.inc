<div id="2026-08-19-focus-queue-p1-trust" class="cl-entry">
<h3>2026-08-19 — Focus Queue ranks trusted blockers, not inflated P1s</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-19 | Tracked: <a href="/todo/details?record_id=1828" class="doc-link">#1828 PLAN-QUEUE Ph4</a> / <a href="/todo/details?record_id=1817" class="doc-link">#1817 priority triage</a>.</p>
            <p class="doc-body">The Focus Queue and /todo list ranked on stored <code>priority</code>. ~248 active rows are still P1, so real work (and any honest P2/P3) sat at rank ~200. Agents were gaming due dates and moving phase todos onto the parent project so they could appear. That is the wrong layer.</p>
            <ul class="doc-body">
                <li><strong>P1 trust:</strong> <code>TodoRanking</code> now scores a stored P1 as P5 unless <code>is_blocking</code> is set or the subject/description is a real incident (<code>[Error]</code>, outage, merge conflict, cannot restore, etc.). Displayed priority is unchanged.</li>
                <li><strong>Reschedule does not refresh freshness.</strong> Staleness uses <code>date_time_posted</code> when <code>last_mod_by=reschedule</code>.</li>
                <li><strong>Recent incidents</strong> get an extra boost so today's error todos beat planned work without rewriting due dates.</li>
                <li><strong>Project filter includes children.</strong> <code>filter_project=272</code> (DRYER-INT) now includes phase projects whose <code>parent_id</code> is 272. No need to reparent todos.</li>
                <li><strong>Per-project cap</strong> of half the Focus Queue (#1828 F5) so one project cannot fill all 20 slots.</li>
                <li><strong>No lunch / appointments in Daily Priorities.</strong> Breaks are created as <code>is_fixed</code> tasks (not <code>todo_type=appointment</code>), so the old type filter missed them. <code>TodoTypes::is_calendar_fixture</code> now drops appointments, meetings, events, reminders, and any subject matching lunch/break/standup. They stay on the calendar.</li>
            </ul>
            <p class="doc-body"><strong>AI assist:</strong> do not ask an LLM to sort 1000 rows on every page load. <code>GET /api/focus/top5</code> already re-ranks the <em>top 50 by ap_score</em>. This scorer change is what makes that candidate pool honest. Stored-priority cleanup remains <a href="/todo/details?record_id=1817" class="doc-link">#1817</a> (batch, local Ollama).</p>
            <p class="doc-body">Files: <code>lib/Comserv/Util/TodoRanking.pm</code>, <code>lib/Comserv/Util/FocusRanking.pm</code>, <code>lib/Comserv/Util/TodoTypes.pm</code>, <code>lib/Comserv/Controller/Planning.pm</code>, <code>t/util_todo_ranking.t</code>.</p>
        </div>
    </div>
</div>
</div>
