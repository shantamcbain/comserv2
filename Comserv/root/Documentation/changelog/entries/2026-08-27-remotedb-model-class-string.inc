<div id="2026-08-27-remotedb-model-class-string" class="cl-entry">
<h3>2026-08-27 — RemoteDB index: instantiate the model, do not call Moose accessors on the class name</h3>
<p class="doc-body"><strong>What.</strong> <code>/remotedb</code> died: Can't use string ("Comserv::Model::RemoteDB") as a HASH ref on the <code>config</code> accessor. <code>RemoteDB</code> is a plain Moose class, so <code>$c-&gt;model('RemoteDB')</code> returns the class name. The controller now does <code>Comserv::Model::RemoteDB-&gt;new</code> when model() is not a ref (same pattern as Root.pm).</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/RemoteDB.pm</code>.</p>
</div>
