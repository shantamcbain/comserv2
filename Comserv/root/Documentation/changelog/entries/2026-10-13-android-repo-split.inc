<div id="2026-10-13-android-repo-split" class="cl-entry">
<h3>2026-10-13 — Phone app source moved to its own repo</h3>
<p class="doc-body"><strong>What.</strong> The Android inventory app is no longer tracked in this tree. Comserv only serves the APK and <code>GET /api/app/version</code>. Accounting and Inventory nav has a Phone app download link.</p>
<p class="doc-body"><strong>Why.</strong> The phone is an HTTP client. Gradle source and build output do not belong in the Perl repo.</p>
<p class="doc-body"><strong>Files.</strong> <code>android/</code> and <code>Comserv/root/static/android/comserv-inventory.apk</code> untracked. <code>.gitignore</code>, <code>Accounting/_acct_inv_nav.tt</code>. Source: <code>/home/shanta/PycharmProjects/comserv-inventory-android</code>.</p>
</div>
