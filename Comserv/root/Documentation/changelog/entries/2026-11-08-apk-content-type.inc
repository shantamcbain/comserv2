<div id="2026-11-08-apk-content-type" class="cl-entry">
<h3>2026-11-08 — Phone app download kept as an APK</h3>
<p class="doc-body"><strong>What.</strong> A newer APK in the Android project's <code>app/build/outputs/apk</code> is copied to <code>/data/nfs/inventory-apks/ComservInventory.apk</code> before the download or the version API answers. The version written beside it is read from the package, not typed into the link. The Phone app button stays a root-relative path so the browser keeps the domain that served the page.</p>
<p class="doc-body"><strong>Why.</strong> The production image's Plack MIME map has no <code>.apk</code> entry, so the file was served as <code>text/plain</code>. Android then saved <code>ComservInventory.apk.txt</code> and would not install it. A bare APK URL also stays cached after a version bump.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/ApkDownload.pm</code>, <code>lib/Comserv/Controller/Root.pm</code>, <code>lib/Comserv/Controller/Api.pm</code>, <code>root/Accounting/_acct_inv_nav.tt</code>, <code>script/comserv_server.psgi</code>, <code>t/apk_download_headers.t</code>.</p>
</div>
