<div id="2026-08-16-ai2-project-tab-file-tree" class="cl-entry">
<h3>AI2 editor Project tab: full project file tree + changed files at top</h3>
<div class="container">

    <h1 class="doc-h1">AI2 editor Project tab — full file tree + changed files on top</h1>

    <div class="last-updated" doc-muted>
        Last Updated: 2026-08-16 | Version: 1.00 | Author: hermes | Status: Implemented (linked to project #238 GITWT-NEW)
    </div>

    <div id="toc" class="row doc-toc">
        <div class="col-100">
            <h2 class="doc-h2">Quick Navigation</h2>
            <div class="doc-navrow">
                <a href="#summary" class="doc-navlink">Summary</a>
                <a href="#behaviour" class="doc-navlink">Behaviour</a>
                <a href="#files" class="doc-navlink">Files</a>
                <a href="#verify" class="doc-navlink">Verification</a>
                <a href="#related" class="doc-navlink">Related</a>
            </div>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="summary" class="doc-h2">1. Summary</h2>
            <p class="doc-body">The AI2 code-editor "Project" sidebar panel previously showed only a hardcoded two-file placeholder (<code>AI2.pm</code>, <code>editing_widget_popup.tt</code>) plus a live "CHANGED FILES" list. It now renders the <strong>entire project file tree</strong> (folders collapsible, with a filter box), and pins a live <strong>CHANGED FILES</strong> section at the top so uncommitted work is always visible first. Each file row is clickable to open it for editing; each row also carries a <strong>Diff</strong> button that opens the file's working-tree diff in the shared <code>#git-diff-pane</code> (same widget the rest of the app uses). Changed files get an <code>M</code> (modified) or <code>U</code> (new/untracked) badge.</p>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="behaviour" class="doc-h2">2. Behaviour</h2>
            <ul class="doc-body">
                <li><strong>Changed files pinned at top.</strong> A <code>GET /ai2/git_status</code> call populates a "CHANGED FILES (N)" header, each row with an <code>M</code>/<code>U</code> badge, a name, and a <strong>Diff</strong> button.</li>
                <li><strong>Full tree below.</strong> A <code>GET /ai2/file_tree</code> call renders the whole project as a nested, collapsible tree (dirs first, then files), rooted at the app dir. A filter box above the tree narrows by full path or base name (empty folders are hidden under a filter).</li>
                <li><strong>Click a file → edit.</strong> Clicking any file row loads it into the Ace editor via the new <code>AI2EditorCore.openFile(path)</code> (reuses <code>/ai2/load_file</code>, resets dirty/save state, updates the tab label + status, and tells the chat sidebar the active file).</li>
                <li><strong>Click Diff → diff.</strong> The <strong>Diff</strong> button (with <code>stopPropagation</code> so it does not also open the file) fetches <code>GET /ai2/file_diff</code> and renders through <code>ComservGitDiff</code> into <code>#git-diff-pane</code>. It reuses <code>ai2editor/file-diff.js</code>'s loader, so the two never clobber the AI-suggestion <code>#ai-diff-pane</code>.</li>
                <li><strong>Badges in the tree.</strong> Tree file rows that also appear in the git-status change-set get the same <code>M</code>/<code>U</code> badge + Diff button, so the whole tree is aware of uncommitted work.</li>
                <li><strong>Diff only on git-changed files.</strong> The <strong>Diff</strong> button is rendered only when git lists the file as changed (M/U). Clean files get no Diff affordance, so the UI never implies a phantom diff on an unchanged file. This is driven entirely by <code>git status --porcelain</code> — if git doesn't flag it, no Diff button.</li>
                <li><strong>Folders start collapsed.</strong> The full tree renders every directory collapsed (▸); click a folder to expand. The filter box narrows by path/base name and hides empty folders.</li>
                <li><strong>Editor re-layouts on resize.</strong> Opening the Project panel or resizing the window/panel now triggers <code>Ace.resize()</code> so the editor content always fills the available area (new <code>AI2EditorCore.resizeEditor</code>, wired to <code>ai2:panel-open</code>/<code>ai2:panel-close</code>/<code>ai2:panel-resize</code> and <code>window.resize</code>).</li>
                <li><strong>Left sidebar is resizable.</strong> The Project/Git/etc. panel container now has a right-edge drag handle (160–600px), so it is no longer fixed-width.</li>
                <li><strong>Bug fix — file_diff "Could not access" on repo-root / app-dir mismatch.</strong> <code>_ai2_repo_rel_path</code> previously assumed the git repo root was one level above the app dir, so when <code>repo_path()</code> resolves the repo to the app dir (<code>Comserv/</code>) while the real <code>.git</code> is at <code>comserv2/</code>, diff paths were rebuilt relative to the wrong root and produced malformed paths like <code>Comserv/Comserv/script/...</code> ("Could not access"). Now it resolves the TRUE toplevel via <code>git rev-parse --show-toplevel</code>, strips it (plus the leading <code>Comserv/</code> app-dir segment, since git resolves relative diff paths against the toplevel), and determines new-vs-tracked via <code>git ls-files --error-unmatch</code> (read-only, added to the Util::Git whitelist) instead of a wrong-base <code>-e</code> check. Files at the repo root (e.g. <code>docker-compose.prod.yml</code>) now diff correctly.</li>
                <li><strong>Layout fix — side panels locked to window edges (no overlap).</strong> The left Project/Git/etc. panel and the right chat sidebar are now proper flex children of <code>.main</code> (the earlier absolute-positioned left panel that floated over and covered the editor is gone). Opening the left panel pushes the editor right; closing it (or hiding the chat) lets the editor expand to fill the freed space — both panels stay pinned to the window edges. The left panel remains drag-resizable (160–600px) and the chat remains resizable.</li>
                <li><strong>UI improvement — diff sits BESIDE the editor (right rail).</strong> The editor area is now a horizontal flex row: code on the left, a right-hand rail (42% width, min 260px) holding the diff panes. The git diff (and the AI suggestion) now render beside the code rather than stacked below it, so you compare them side-by-side without scrolling. The git-diff pane fills the rail height and keeps its Unified/Split toggle.</li>
                <li><strong>Chat detach hardened.</strong> The detach/attach toggle and the detached-window construction are now wrapped in try/catch with guarded <code>window.opener</code> access and no aggressive <code>setInterval</code> watchers, so a blocked popup or opener error can no longer crash the editor window. Close (✕) + floating 💬 reopen + detach (⤢) all share one view-state function; closing the detached window re-attaches cleanly without forcing the chat open if it was also closed.</li>
                <li><strong>Diff correctness — deployment-agnostic path resolution (final fix).</strong> The remaining "shows as new" bug was traced to <code>_ai2_repo_rel_path</code> computing the git prefix via <code>git rev-parse --show-prefix</code> run from <code>repo_path()</code> (the repo root), where that prefix is <code>""</code> — so the returned pathspec lost the <code>Comserv/</code> segment and <code>git diff HEAD</code> matched nothing (→ <code>is_new=1</code> → "new file"). Replaced with <code>File::Spec::abs2rel($app_dir, $repo_root)</code> (the relative path from the repo root down to wherever the code actually runs), joined with the app-relative path. This is exact, deterministic, deployment-agnostic, and never depends on git's cwd or a hardcoded string. Verified via a direct invocation of the controller logic: <code>lib/Comserv/Controller/Admin/Docker.pm</code> now resolves to <code>Comserv/lib/Comserv/Controller/Admin/Docker.pm</code>, <code>is_new=0</code>, and a real 132-line modification diff. <strong>U = untracked</strong> (never committed); <strong>M = modified</strong> (tracked file changed vs HEAD).</li>
                <li><strong>Title-bar Diff button + scroll-lock.</strong> The editor title bar now has a <strong>Diff</strong> button that shows the currently-open file's git diff in the right rail (same as clicking a tree/file Diff). Scrolling the code and the diff now stay in lock-step (proportional scroll-sync, guarded against feedback loops) so the same lines remain visible in both.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="files" class="doc-h2">3. Files changed</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/AI2.pm</code> — new <code>file_tree :Local</code> action: editor/admin/developer-gated, pure <code>readdir</code> recursion (no shell, no chdir), path-confined to the app root, skips <code>.git</code>/<code>node_modules</code>/<code>blib</code>/<code>.hermes</code>/<code>logs</code>/<code>tmp</code>/vendor dirs and <code>.bak</code>/<code>.swp</code>/<code>.tmp</code> files. Returns <code>{ success, root, tree }</code> where <code>tree</code> is a nested <code>{ type, name, path, children? }</code> structure.</li>
                <li><code>root/static/js/ai2editor/core.js</code> — new <code>AI2EditorCore.openFile(path)</code>: on-demand loader that sets the Ace value, resets dirty/save state, updates tab label/status, and notifies the chat/popup of the active file. Safe to call before Ace is ready (brief poll). Also new <code>AI2EditorCore.resizeEditor()</code> (guarded so it never creates a stray empty editor) wired to <code>window.resize</code> + <code>ai2:panel-open/close/resize</code> events.</li>
                <li><code>root/static/js/ai2editor/sidebar-toggle.js</code> — new <code>wireResize()</code>: adds a right-edge drag handle to the <code>#sidebar-panels</code> container (160–600px) so the left panel is resizable; dispatches <code>ai2:panel-resize</code> and <code>ai2:panel-close</code> events.</li>
                <li><code>root/static/js/ai2editor/project-tree.js</code> — Diff button rendered ONLY for git-changed files (M/U); directories render collapsed by default; filter box hides empty folders.</li>
                <li><code>root/ai2/editor/editing_widget_popup.tt</code> — removed the hardcoded 2-file <code>ul.file-tree</code> placeholder from <code>#panel-projects</code>; kept the <code>#ai2-changed-files</code> host (module injects the filter + tree itself).</li>
                <li><code>root/js_load.tt</code> — loads <code>ai2editor/project-tree.js</code> (defer) on the <code>/ai2/editing_widget_popup</code> route, after core.js + the shared diff widget + file-diff.js.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="verify" class="doc-h2">4. Verification</h2>
            <ul class="doc-body">
                <li><code>perl -c -I lib lib/Comserv/Controller/AI2.pm</code> — syntax OK.</li>
                <li><code>node --check root/static/js/ai2editor/project-tree.js</code> and <code>root/static/js/ai2editor/core.js</code> — syntax OK.</li>
                <li>Open the editor (<code>/ai2/editing_widget_popup</code>), click the Project icon: the full tree + filter box appear, and CHANGED FILES (if any) sit at the top. Click a file → it loads into Ace. Click Diff → the diff renders. Server auto-reloads (no restart).</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="related" class="doc-h2">5. Related</h2>
            <ul class="doc-body">
                <li><a href="/Documentation/changelog#2026-08-15-git-diff-viewer-shared-widget" class="doc-link">2026-08-15 — shared diff widget built</a> (the widget the Diff button renders into).</li>
                <li><a href="/Documentation/changelog#2026-08-15-git-file-diff-no-index-fix" class="doc-link">2026-08-15 — git file_diff --no-index fix</a>.</li>
                <li><a href="/Documentation/system/git_worktree_merge_plan" class="doc-link">git_worktree_merge_plan.tt</a> §3.5 (project #238).</li>
                <li><a href="/project/details?project_id=238" class="doc-link">Project #238 (GITWT-NEW)</a>.</li>
                <li><a href="/Documentation/MASTER_PLAN" class="doc-link">MASTER_PLAN.tt</a>.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <div class="doc-footer">
                <p>Owning project: <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>. AI2 editor Project panel enhancement. Cross-linked from MASTER_PLAN.</p>
                <p><em>This documentation is part of the Comserv system.</em></p>
            </div>
        </div>
    </div>

</div>
</div>

<h2>2026-08-13 — /planning/daily rebuilt as a clean index (replaced the broken monolith)</h2>

<p><strong>Decision:</strong> After multiple failed attempts to patch the floating buttons
(AI Editor / Back-to-Top / Chat) on the old <code>/planning/daily</code> monolith, the page
was rebuilt from scratch per the owner's direction. The old monolith trapped the global
<code>position:fixed</code> floating buttons inside its nested tab content (full-page
<code>?tab=</code> fetches were injected via <code>innerHTML</code>), making the buttons
unreachable. Patching CSS/JS on top of that structure was whack-a-mole.</p>

<p><strong>New structure:</strong></p>
<ul>
    <li><code>/planning/daily</code> is now a <strong>clean index page</strong> (<code>admin/planning/DailyPlan.tt</code>) with three <strong>hard-coded links</strong>: <strong>Daily Priorities</strong>, <strong>Master Plan</strong>, <strong>Calendar</strong>. It is a normal page, so the global floating buttons (Back-to-Top / AI Editor / Chat from <code>layout.tt</code>/<code>js_load.tt</code>) render correctly — the nested full-page injection that broke them is gone.</li>
    <li><strong>Daily Priorities</strong> → new route <code>/planning/daily-priorities/&lt;date&gt;</code> (<code>Planning.pm sub daily_priorities</code>) renders <code>admin/planning/DailyPriorities.tt</code>, which INCLUDEs the existing <code>_today_work_tab.tt</code> (Start Day / End Day / Triage / Reschedule / Today's Log action bar, focus queue, remaining-todos). Verified: action bar + focus queue render.</li>
    <li><strong>Calendar</strong> → links to <code>/todo/day/&lt;date&gt;</code>, the existing gcal <strong>day calendar</strong> view (the real day-grid, not a todo list).</li>
    <li><strong>Master Plan</strong> → links to <code>/Documentation/MASTER_PLAN</code> (unchanged, working).</li>
    <li><strong>Old monolith preserved</strong> as <code>admin/planning/DailyPlan.legacy.tt</code>, served read-only at <code>/planning/daily-legacy</code> (new <code>legacy_daily</code> action → refactored <code>daily_impl</code> private method). Kept for reference; does NOT carry live data when opened standalone and is intended to be re-integrated later as a tab on the main page.</li>
</ul>

<p><strong>Verified:</strong></p>
<ul>
    <li><code>perl -Ilib -c lib/Comserv/Controller/Planning.pm</code> &rarr; syntax OK.</li>
    <li>Rendered <code>DailyPlan.tt</code> (index) and <code>DailyPriorities.tt</code> through the app's Template Toolkit: index emits all three hard-coded links; Daily Priorities emits the action bar (Start Day / End Day / Triage / Reschedule / Today's Log) and focus-queue section.</li>
    <li>Routes present: <code>daily</code> (<code>/planning/daily</code>), <code>daily_priorities</code> (<code>/planning/daily-priorities</code>), <code>legacy_daily</code> (<code>/planning/daily-legacy</code>); <code>daily_log</code> untouched.</li>
</ul>

<p><strong>Files touched:</strong></p>
<ul>
    <li><code>lib/Comserv/Controller/Planning.pm</code> — <code>daily</code> now renders the clean index; added <code>daily_priorities</code> + <code>legacy_daily</code> + private <code>daily_impl</code>.</li>
    <li><code>root/admin/planning/DailyPlan.tt</code> — rewritten as the clean index (was the monolith; old version moved to <code>DailyPlan.legacy.tt</code>).</li>
    <li><code>root/admin/planning/DailyPriorities.tt</code> — new focused Daily Priorities page.</li>
    <li><code>root/static/css/planning/daily-plan.css</code> — added <code>.daily-index*</code> card styles (theme-token driven, no fixed geometry).</li>
</ul>

<p><strong>Next steps (add one feature at a time):</strong> re-introduce the week / month / gantt / resources views as their own routes or lazy-loaded fragments; eventually re-surface the legacy monolith as a tab on the main index.</p>

<h2>2026-08-13 — Removed duplicate action bar on /planning/daily; added End Day + Open Logs</h2>

<p><code>/planning/daily</code> rendered two identical action bars: a top-level "Day Controls" card above the tab bar and a second one inside the Daily Priorities tab. The second (in-tab) bar was the duplicate and is now hidden on this page via <code>hide_action_bar = 1</code> on the <code>_today_work_tab.tt</code> include; the top card stays as the only action bar. <strong>End Day</strong> and <strong>Open Logs</strong> were added to that card and are now always visible (previously Start Day / Open Logs / End Day were mutually exclusive based on log state). No other buttons changed. The shared inner bar still shows on DailyPriorities and DailyPlan.legacy. See <a href="/Documentation/changelog#2026-08-13-daily-plan-remove-duplicate-action-card">the full note</a>.</p>
