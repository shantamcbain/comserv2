<div id="2026-08-20-todo-card-theme-branch-sort" class="cl-entry">
<h3>2026-08-20 — Todo cards: black-on-light default; branch queue Active → blockers → branch work</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-muted">Last Updated: 2026-08-20 | Version: 1.00 | Tracked in project: <a href="/project/details?project_id=138" class="doc-link">#138 (PLANNING)</a>.</p>
            <p class="doc-body">Todo cards on <code>/planning/daily</code> were white text on gray because the shared card wrapper carried <code>pri-N</code>. P7–P10 in the theme painted the <em>whole card</em> <code>color:#fff</code> on muted gray. Priority colour is now badge-only (<code>.badge.pri-N</code>). Global card text default is <code>var(--text-color, #000)</code> on a light <code>--card-bg</code>; dark themes still override <code>--text-color</code>.</p>
            <p class="doc-body">Branch Focus Queue sort is now: <strong>Active (any branch)</strong> first so nobody starts a todo already in a work log, then <strong>blockers from any branch</strong>, then this branch's project todos by scored priority. <code>/planning/daily</code> no longer forwards into <code>daily_impl</code> (that overwrite hid the branch filter).</p>
            <p class="doc-body">Files: <code>todo_card.tt</code>, <code>base-containers.css</code>, <code>todo.css</code>, <code>todo_shared.css</code>, <code>Header.tt</code>, <code>Planning.pm</code>, <code>FocusRanking.pm</code>.</p>
        </div>
    </div>
</div>
</div>
