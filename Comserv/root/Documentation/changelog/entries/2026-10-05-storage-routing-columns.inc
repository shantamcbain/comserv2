<div id="2026-10-05-storage-routing-columns" class="cl-entry">
<h3>2026-10-05 — Storage routing columns for File table</h3>
<p class="doc-body"><strong>What.</strong> Added <code>repo_path</code> (varchar 1000, nullable) column to the <code>files</code> table and documented the extended <code>source_type</code> semantics (<code>db</code> / <code>git</code> / <code>nfs</code>) in the Result class inline comment.</p>
<p class="doc-body"><strong>Why.</strong> The app needs to route file storage by content type — DB blobs for small metadata-ish files, git-tracked repo paths for repo-native assets (e.g. PDF books under <code>Documentation/</code>), NFS for big/uploads. All existing code is backward-compatible: <code>source_type</code> default stays <code>'nfs'</code>, <code>repo_path</code> is nullable, and no production code checks for the new values yet.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Schema/Ency/Result/File.pm</code></p>
</div>