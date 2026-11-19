<div id="2026-11-19-schema-merge-conflict-markers" class="cl-entry">
<h3>2026-11-19 — schema branch: committed conflict markers broke the test gate</h3>
<p class="doc-body"><strong>What.</strong> The fast test gate for <code>schema</code> failed with
<em>Version control conflict marker</em> plus <em>Global symbol "$router" requires explicit
package name</em>. Two files carried unresolved merge-conflict hunks that had already been
<em>committed</em> (commit <code>4972f77e0</code>): <code>Model/AI2/GitFix.pm</code> (1 block) and
<code>Model/AI2/Router.pm</code> (2 blocks). <code>t/01app.t</code> and
<code>t/bot_prevention_and_purging.t</code> aborted at app compile, so no subtests ran.</p>
<p class="doc-body"><strong>Why.</strong> Both resolutions had to be semantic, not a side pick.
<strong>GitFix:</strong> <code>main</code>'s hunk was the old router-LLM diagnosis
(<code>$router</code>/<code>$analysis_model</code>/<code>$analysis_prompt</code> — undeclared here, which
is what raised the global-symbol errors); the branch deliberately replaced it with the deterministic
"quote the <code>Admin/Git.pm</code> validator source, no model call" answer documented in the POD.
Kept the branch side, dropped the dead model-call hunk (also removed the duplicate
<code>my $response</code>). <strong>Router:</strong> the classifier timing hunk and the
<code>if/else</code> restructure were split across the two sides, so the merged text lost the closing
brace of <code>} else {</code> (and of the <code>sg_ruled</code> block) — <em>Missing right curly at EOF</em>.
Resolution keeps both features: close the <code>else</code> after the <code>if ($@)</code> block, keep the
branch's rule-based SuperGrok floor with its own closing brace, then the per-stage timing log.
The editor-agent lookup keeps the single definition via <code>ChatIntent::is_editor_agent</code>
(which delegates to <code>ModelPick->is_editor_agent</code>) instead of <code>main</code>'s duplicate
<code>ModelPick</code> call.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AI2/GitFix.pm</code>,
<code>Comserv/lib/Comserv/Model/AI2/Router.pm</code></p>
<p class="doc-body"><strong>Verification.</strong> <code>git grep '^&lt;&lt;&lt;&lt;&lt;&lt;&lt;'</code> finds no
markers in the worktree; <code>perl -c</code> clean on both files and on all 0-failure sweep of
<code>lib/**/*.pm</code>; <code>prove t/01app.t t/controller_AI_models.t t/bot_prevention_and_purging.t</code>
→ <code>All tests successful. Files=3, Tests=17</code>.</p>
</div>
