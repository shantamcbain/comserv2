<div id="2026-09-04-fix-membership-template-parse" class="cl-entry">
<h3>2026-09-04 — Fix membership template parse error</h3>
<p class="doc-body"><strong>What.</strong> Template parse error: unexpected token (END) at membership/Index.tt line 301 — an orphan [% END %] with no matching opener.</p>
<p class="doc-body"><strong>Why.</strong> A stray [% END %] directive was inserted in the wrong position within the plans section, breaking the Template Toolkit parse chain. The END appeared after the plan card closing </div> but before the [% ELSE %] for the IF plans.size block, causing the parser to fail.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/membership/Index.tt</code> — removed two unbalanced [% END %] tags inside the FOREACH plan loop and added the missing FOREACH END. Updated PageVersion header + debug echo block per .tt page contract.</p>
</div>