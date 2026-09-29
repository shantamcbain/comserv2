<div id="2026-09-24-model-15-stale-nfs-path" class="cl-entry">
<h3>2026-09-24 — Deactivate HDRY plate models with retired nfs_path</h3>
<p class="doc-body"><strong>What.</strong> Error-audit todo #2425: <code>3d::model_download</code> logged ERROR for model 15 because <code>nfs_path</code> pointed at <code>/data/nfs/3d/projects/hdry-v3/…3mf</code> (directory gone after NFS restructure). Plate rows 11–16 were project_import 3MF records, not printable parts. Parts already exist as STL models under <code>/data/nfs/hdry_parts/…</code> (e.g. models 44/45/47). Set those six rows <code>is_active=0</code> and cleared <code>nfs_path</code> via DBIC Result so download hits the early “no file” path instead of the ERROR log.</p>
<p class="doc-body"><strong>Why.</strong> Auto-error-audit from a stale plate download. Do not re-point a plate at a random STL; do not teach download to stream directories.</p>
<p class="doc-body"><strong>Files.</strong> Data: <code>printing_3d_models</code> id 11–16 (sitename 3d). No controller change.</p>
</div>
