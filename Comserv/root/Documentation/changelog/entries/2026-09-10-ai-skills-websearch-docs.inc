<div id="2026-09-10-ai-skills-websearch-docs" class="cl-entry">
<h3>2026-09-10 — Document the skills + web-search design and link it in-app</h3>
<p class="doc-body"><strong>What.</strong> Added a served documentation page
describing the v2 skills and web-search design, linked it from the AI system
coordinator, and brought the working plan files up to date with what has
actually landed.</p>
<p class="doc-body"><strong>Why.</strong> Several decisions recorded only in chat
would otherwise be lost: why skills live in MariaDB rather than a JSON config,
why an AI-written skill requires human approval, why search is self-hosted
rather than a hosted API, and that the web-search toggle never worked because
the flag was dropped mid-chain. These now live where the app can render them.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/root/Documentation/AiSkillsAndWebSearch.tt</code> (new — META
block, PageVersion header, debug echo, themed with CSS variables only) ·
<code>Comserv/root/Documentation/AISYSTEMPlan.tt</code> (new section 5b + TOC
link) ·
<code>.hermes/plans/2026-09-09-v2-agent-tools-skills-websearch.md</code>
(status 6/14, steps marked done, blockers recorded) ·
<code>.hermes/plans/2026-09-09-v2-agent-context-engineering.md</code> (marked
SUPERSEDED so it is not executed alongside the current plan)</p>
<p class="doc-body"><strong>Verification.</strong> Both templates have balanced
<code>[% META %]</code> / <code>[% IF %]</code> / <code>[% END %]</code> blocks
and one <code>INCLUDE</code>. Every table-of-contents anchor on the new page
resolves to a real element id (8 anchors, none missing). No hardcoded hex
colours — the page uses theme variables per the documentation contract.</p>
<p class="doc-body"><strong>Standing constraints restated in the docs.</strong>
Table creation belongs to the <code>schema</code> branch via in-app
schema-compare — never hand-authored DDL. The search container ships disabled
and is built or started only by a human.</p>
</div>
