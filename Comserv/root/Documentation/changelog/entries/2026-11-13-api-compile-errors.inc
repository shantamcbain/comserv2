<div id="2026-11-13-api-compile-errors" class="cl-entry">
<h3>2026-11-13 — Fix compile errors that blocked app restart</h3>
<p class="doc-body"><strong>What.</strong> Three modules could not compile, so a fresh
start of the app aborted during component load: <code>Controller::Api</code> had a
pasted duplicate of <code>api_inventory_suppliers</code> /
<code>api_inventory_supplier_create</code> plus two stray closing braces
(unmatched <code>}</code> / undeclared <code>$c</code>); <code>Controller::Hosting</code>
and <code>Controller::ProxyManager</code> used <code>JSON::true</code> /
<code>JSON::false</code> while only <code>JSON::MaybeXS</code> was imported, and
<code>Model::AI::Router</code> used the same barewords with no JSON import at all
(its <code>decode_json</code> was undefined too).</p>
<p class="doc-body"><strong>Why.</strong> Catalyst loads every Controller/Model at
setup, so one un-compilable file means the server never comes up — the running
process was simply an old one that predated the broken code.</p>
<p class="doc-body"><strong>Fix.</strong> Removed the duplicated handler block and the
stray braces (the thin delegating wrappers higher in <code>Api.pm</code> are the
intended definitions); replaced the JSON barewords with JSON boolean references
(<code>\1</code>/<code>\0</code>) and added the missing
<code>use JSON::MaybeXS qw(decode_json)</code> to <code>Model::AI::Router</code>.
Verified: 652/652 modules under <code>lib/Comserv</code> pass
<code>perl -c</code> and <code>Comserv-&gt;new</code> completes with 1122 components /
117 controllers.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Controller/Api.pm</code>,
<code>Comserv/lib/Comserv/Controller/Hosting.pm</code>,
<code>Comserv/lib/Comserv/Controller/ProxyManager.pm</code>,
<code>Comserv/lib/Comserv/Model/AI/Router.pm</code></p>
</div>
