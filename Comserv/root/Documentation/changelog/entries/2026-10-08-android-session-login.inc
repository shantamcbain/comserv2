<div id="2026-10-08-android-session-login" class="cl-entry">
<h3>2026-10-08 — Android inventory login replaces API token</h3>
<p class="doc-body"><strong>What.</strong> The inventory phone app now signs in with the same username and password as the web app and keeps that session cookie. LAN uses <code>.local</code>. ZeroTier uses <code>.zero</code>. Only one network is selected. A colour photo count page writes the counted quantity and location through the existing stock adjust.</p>
<p class="doc-body"><strong>Why.</strong> The browser cannot open the camera on <code>http://</code>. The phone must act as the logged-in admin, not as a pasted API token. ZeroTier and the shop LAN are never up together.</p>
<p class="doc-body"><strong>Files.</strong> <code>android/app/src/main/java/com/comserv/inventory/</code>, <code>Comserv/lib/Comserv/Controller/Api.pm</code></p>
</div>
