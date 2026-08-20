<div id="2026-08-19-floating-button-theme-respect-todo" class="cl-entry">
        <h2>2026-08-19 — Floating buttons (Chat with AI + Back-to-Top): theme-respect todo #2160 + plan/doc sync</h2>
        <p><strong>Last Updated:</strong> 2026-08-19 | <strong>Version:</strong> 1.00 | <strong>Author:</strong> hermes | <strong>Status:</strong> Tracked (linked to project #221 THEME-AUDIT; shared with #259 V2MIG)</p>

        <div class="row">
            <div class="col-100">
                <h3 class="doc-h3">What changed</h3>
                <ul class="doc-body">
                    <li>Created todo <a href="/todo/details?record_id=2160" class="doc-link">#2160</a> under <strong>proj #221 Theme Compliance Audit</strong> (cross-referenced to <strong>proj #259 V2MIG</strong> for the V2 JS/CSS migration). Subject: <em>"Floating buttons (Chat with AI + Back-to-Top) ignore theme/placement rules — fix in V2 JS/CSS"</em>.</li>
                    <li>Registered #2160 in <code>Documentation/MASTER_PLAN.tt</code> as a sub-item of the #221 Theme Compliance Audit bullet, with a note that it is distinct from the <code>c6bd92b6</code> zombie-button / duplicate-arrow fix (that was a stale <code>localStorage</code> flag, not placement).</li>
                    <li>Updated <code>Documentation/features/back_to_top.tt</code> to correct the implementation notes (the button is fixed <strong>bottom-LEFT</strong> at <code>bottom:20px;left:20px</code>, not bottom-right as the old doc claimed), document that it is wired by both <code>back-to-top.js</code> and <code>floating-buttons.js</code>, note the removed duplicate <code>.back-to-top</code> injected by <code>todo-enhancements.js</code>, and add a theme-governance callout + Future-Enhancement item pointing at todo #2160.</li>
                </ul>
            </div>
        </div>

        <div class="row">
            <div class="col-100">
                <h3 class="doc-h3">Root cause the todo addresses</h3>
                <ul class="doc-body">
                    <li>The floating <em>Chat with AI</em> (<code>.chat-button</code>) and <code>#back-to-top</code> buttons use hardcoded <code>position:fixed</code> offsets, z-index, and colors (literals, not theme <code>var(--*)</code> tokens). AI-authored edits therefore repeatedly break their placement and collide with the AI2 float button (<code>bottom:90px;left:24px</code>).</li>
                    <li>Forward fix (todo #2160): drive offsets/z-index/colors from theme variables so the theme system controls placement, make the rule survive AI edits without drift, and guarantee no collision with other floating elements.</li>
                </ul>
            </div>
        </div>

        <div class="row">
            <div class="col-100">
                <h3 class="doc-h3">Files touched (documentation only — no code behavior changed)</h3>
                <ul class="doc-body">
                    <li><code>root/Documentation/MASTER_PLAN.tt</code> — #221 bullet extended with todo #2160 sub-item.</li>
                    <li><code>root/Documentation/features/back_to_top.tt</code> — corrected implementation/theme notes + #2160 cross-reference.</li>
                    <li><code>root/Documentation/changelog/CHANGELOG.tt</code> — this entry + TOC anchor.</li>
                </ul>
                <p class="doc-note"><strong>Note:</strong> the actual bug fixes (zombie popup-active flag + removal of the injected duplicate <code>.back-to-top</code>) shipped earlier in commit <code>c6bd92b6</code>. This entry only records the planning/documentation sync for the separate theme-respect governance task.</p>
            </div>
        </div>
        <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="root" class="doc-h2">2. Root cause</h2>
            <ul class="doc-body">
                <li>"unexpected end of input at line 34" means the Template Toolkit parser hit EOF while still inside a <code>&#91;% ... %&#93;</code> block &mdash; i.e. the file was <strong>truncated at render time</strong>. This is the classic signature of an edit/deploy race on a running container: a <code>.tt</code> was being written/replaced while the live server reloaded it mid-write and read a half-written copy.</li>
                <li>The error is not a persistent source defect. Nothing in the source changed between the image build and the error, and once the file finished writing the page renders normally.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="evidence" class="doc-h2">3. Evidence</h2>
            <ul class="doc-body">
                <li><code>root/ai/index.tt</code> currently = 1111 lines, balanced <code>&#91;%/%%&#93;</code> tags, and parses cleanly through Template Toolkit (verified: 37,878-char render, no error).</li>
                <li>The image it was baked from (<code>fbbc501c</code>, built 2026-08-16 01:08, the <code>version.json</code> commit) also has the complete 1111-line file; the only <code>&#91;% PROCESS %&#93;</code> target (<code>ai/model_select.tt</code>) is complete (79 lines).</li>
                <li>Last commit touching <code>ai/index.tt</code> (<code>61c7573c</code>, 2026-08-11) predates the error and is also complete &mdash; so this was not a broken commit that later got fixed.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="verify" class="doc-h2">4. Verification</h2>
            <ul class="doc-body">
                <li>Template parsed with <code>Template-&gt;new-&gt;process($file, {}, \$out)</code> &rarr; OK (no parse error).</li>
                <li>The container that logged it (<code>workstation-prod-local (Docker):5000</code>) is not currently running in this environment, so it cannot re-error.</li>
                <li>Verdict: no code change required; the source is correct and the parse failure cannot reproduce from it.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <div class="doc-footer">
                <p><em>This is a diagnostic/closure note for an Application Error Audit todo. No files changed.</em></p>
                <p><em>This documentation is part of the Comserv system.</em></p>
            </div>
        </div>
    </div>
</div>
