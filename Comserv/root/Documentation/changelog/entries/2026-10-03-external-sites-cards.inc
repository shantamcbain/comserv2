<div id="2026-10-03-external-sites-cards" class="cl-entry">
<h3>2026-10-03 — 3D Browse: External Sites branded card grid</h3>
<p class="doc-body"><strong>What.</strong> Added an always-visible "External Sites" card grid at the bottom of
<code>3d/browse.tt</code> — one card per external model repository (Printables, MakerWorld, Thangs,
Cults3D, Thingiverse, MyMiniFactory, CGTrader, Gambody, Pinshape, YouMagine, Anycubic). Each card
shows the site's <strong>real logo</strong> (fetched from the site, stored in
<code>root/static/images/3d/sites/&lt;code&gt;.png</code>) on a header band tinted with a brand accent
color sampled from that logo's dominant pixel — no hardcoded approximations or emoji stand-ins.
Each card is a single link that opens in a new tab: with a search query typed it is the
<strong>external site's own search page</strong> (<code>https://www.thingiverse.com/search?q=…</code>,
Pinshape <code>/items?search=…</code>, Printables <code>/search/all-models?q=…</code>) carrying the
AI-augmented term when a deep search ran, otherwise the query; with no query it opens the site's
homepage. The search URL is assembled in Perl with <code>URI::Escape</code> (TT2's <code>| uri</code>
filter does not escape reliably; an earlier placeholder <code>%s</code> approach leaked through to
the site) and the 11-site list lives once in <code>Comserv::Controller::3d::_external_sites</code>.</p>
<p class="doc-body"><strong>Why.</strong> The user asked for cards that look like each external site's
branding so users can search those repositories. Earlier attempts failed on three counts:
hardcoded hex/emoji branding, a second "Search this site" link that made the card's action
ambiguous, and linking card clicks to the app's own local SearXNG results instead of the external
site's search. Final behavior: real logo branding, one unambiguous link per card, and the click
searches the external site itself.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/3d.pm</code> ·
<code>Comserv/root/3d/browse.tt</code> · <code>Comserv/root/static/images/3d/sites/*.png</code> (new)</p>
</div>