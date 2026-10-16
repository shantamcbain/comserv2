<div id="2026-10-16-mobile-nav-class-toggle" class="cl-entry">
<h3>2026-10-16 — Phone menu follows window width, not an inline script</h3>
<p class="doc-body"><strong>What.</strong> The top menu now collapses under 1024px (and on coarse touch screens). A hamburger toggles <code>nav-open</code>. Tapping a menu name opens an accordion. JavaScript no longer writes inline <code>display</code> on the menu.</p>
<p class="doc-body"><strong>Why.</strong> <code>sub-menu.js</code> forced a desktop row, so the existing hamburger CSS never won. Hover flyouts ran off a phone. Narrowing a desktop window is the check: at 1024px or less the hamburger layout must appear.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/sub-menu.js</code>, <code>root/static/css/menu-theme.css</code>, <code>root/pagetop.tt</code>. Plan: project #305, <code>/Documentation/CSSNavigationPlan</code>.</p>
</div>
