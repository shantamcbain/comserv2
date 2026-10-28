<div id="2026-09-10-ai-skills-result-and-search-scaffold" class="cl-entry">
<h3>2026-09-10 — AiSkill Result class (DB-backed, approval-gated) and self-hosted search scaffold</h3>
<p class="doc-body"><strong>What.</strong> Two pieces: (1) a new
<code>ai_skills</code> Result class so AI skills live in the database, and
(2) a self-hosted search service scaffold (<code>comserv2-search</code>) with a
Perl client, because OpenRouter's <code>search_domain_filter</code> is silently
ignored.</p>
<p class="doc-body"><strong>Why — skills in the DB, not JSON.</strong> A JSON
config under <code>root/static/config/</code> only reaches production at the next
deploy and is mutated independently per branch. DB rows are live everywhere
immediately. Approval is mandatory because an AI-written skill must not be able
to change behaviour without a human decision: only
<code>status='approved'</code> rows are ever injected into a prompt; new rows
default to <code>pending</code>, and non-admin submissions are queued for admin
attention.</p>
<p class="doc-body"><strong>Why — self-hosted search.</strong> Measured
2026-09-09: a strict <code>en.wikipedia.org</code> domain filter sent through
OpenRouter's <code>web_search_options</code> returned zero Wikipedia results and
16 off-filter hosts. Scope control therefore requires a service we run.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/AiSkill.pm</code> (new) ·
<code>Comserv/lib/Comserv/Model/Schema/Ency.pm</code> (register_class) ·
<code>Comserv/lib/Comserv/Model/AI2/Search.pm</code> (new) ·
<code>services/search/{Dockerfile,docker-compose.yml,settings.yml}</code> (new) ·
<code>Comserv/root/config/services.json</code> (search entry, <code>enabled:0</code>)</p>
<p class="doc-body"><strong>Verification.</strong> <code>perl -c</code> clean on
all Perl. DBIC resolves <code>table=ai_skills</code>, <code>pk=id</code>, unique
constraint on <code>skill_key</code>. A 16-assertion harness on
<code>AI2::Search</code> covers disabled-by-default (no config / enabled=0 /
enabled-but-no-url all disabled), that a disabled service performs no request,
that <code>sites</code> become <code>site:</code> OR operators, that malformed
site entries are rejected, and that <code>context_block</code> emits URLs so the
model can cite sources.</p>
<p class="doc-body"><strong>Table creation.</strong> Deliberately NOT done here —
the <code>schema</code> branch owns table creation, and the sanctioned path is
in-app schema-compare, never hand DDL. Tracked as todo <strong>#2430</strong>.</p>
<p class="doc-body"><strong>Safety.</strong> The search service ships
<code>enabled: 0</code>; while disabled every call returns
<code>disabled =&gt; 1</code> with no network traffic. The container is not built
or started by this change.</p>
</div>
