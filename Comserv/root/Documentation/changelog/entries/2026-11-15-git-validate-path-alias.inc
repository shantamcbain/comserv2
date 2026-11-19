<div id="2026-11-15-git-validate-path-alias" class="cl-entry">
<h3>2026-11-15 — Git writes: app-relative paths accepted; GitFix decision model leaves the 0.8B</h3>
<p class="doc-body"><strong>What.</strong> Committing from the AI editor / Git dashboard failed with
<em>"Rejected unsafe or unknown path(s): data/ai_trials/particle_1.state.json"</em> even though that
file was genuinely modified. Separately, the <code>=== Structured Recommendation ===</code> block of
GitFix returned the caller's own prompt echoed back as JSON (a <code>tev1:0.8b</code> failure).</p>
<p class="doc-body"><strong>Why — a path-base mismatch, not quoting or renames.</strong>
<code>git status --porcelain</code> reports <strong>repo-root-relative</strong> paths
(<code>Comserv/data/ai_trials/particle_1.state.json</code>; toplevel is
<code>…/aisystem/Comserv</code>), while the editor/dashboard collector submits
<strong>app-dir-relative</strong> paths (<code>data/…</code>, the app lives one level below the
toplevel). <code>Admin::Git::_validate_paths</code> compared the two literally, so every legitimate
commit from the editor was rejected while the same path prefixed with <code>Comserv/</code> was in the
change set. The validator's prefix/rename/traversal handling was already correct — the missing piece
was the base.</p>
<p class="doc-body"><strong>Solution.</strong> <code>_validate_paths</code> now computes the app-dir
prefix relative to the target repo toplevel once (local targets only), and retries a candidate as
<code>prefix + path</code> when it is not in the porcelain set; a hit is canonicalised to the
root-relative form (which is also what <code>git add</code> is later given), logged as
<code>resolved app-relative path …</code>, and the rejection message now names the accepted prefix.
The alias can only <em>prepend</em>, so the traversal/absolute guards and the symlink-escape check are
untouched; SSH targets never get an alias. GitFix's decision stage now asks the same Hermes chain the
rest of the editor uses (<code>gitfix-decision</code> → particle-1 today) and keeps
<code>ollama|tev1:0.8b</code> only as the nothing-live fallback; the header names the model that
actually answered.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Admin/Git.pm</code>
(<code>_validate_paths</code> alias + rejection hint, returns <code>alias_prefix</code>),
<code>lib/Comserv/Model/AI2/GitFix.pm</code> (chain-chosen decision model),
<code>t/git_validate_paths_alias.t</code> (new, 9 tests),
<code>t/ai2_editor_coding_chain_path.t</code> (GitFix case extended).</p>
</div>
