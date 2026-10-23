<div id="2026-10-22-forager-header-icon" class="cl-entry">
<h3>2026-10-22 — Forager leaf moves to the application header</h3>
<p class="doc-body"><strong>What.</strong> The application header now shows <code>sites.app_logo</code> for the current SiteName. A path or URL is an image; any other non-empty value is a glyph; blank shows nothing. The leaf was removed from the Forager home welcome.</p>
<p class="doc-body"><strong>Why.</strong> The leaf belonged in the shared header, but only for SiteName Forager. Other sites keep their own logo or none. A Forager-only branch in the header would leak the wrong icon.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/pagetop.tt</code>, <code>root/Forager/index.tt</code>, <code>root/static/css/menu-theme.css</code>. Forager <code>sites.app_logo</code> set to the leaf glyph.</p>
</div>
