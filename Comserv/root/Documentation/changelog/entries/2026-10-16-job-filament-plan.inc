<div id="2026-10-16-job-filament-plan" class="cl-entry">
<h3>2026-10-16 — Per-tool filament plan for print complete</h3>
<p class="doc-body"><strong>What.</strong> Added Result <code>Printing3dJobFilament</code> (<code>printing_3d_job_filaments</code>) so a multi-filament send can store one row per tool. Complete and reopen read those rows and issue or return each spool. Grams on the row are one plate, flush included; complete multiplies by the job quantity.</p>
<p class="doc-body"><strong>Why.</strong> The job row holds one spool. Completing the two-tool dice print was guessing colours and charging one filament. The table is created in schema-compare, not by hand DDL. No columns were added to <code>printing_3d_jobs</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>Result/Printing3dJobFilament.pm</code>, <code>Result/Printing3dJob.pm</code>, <code>Util/Printing3d.pm</code>, <code>Controller/3d.pm</code></p>
</div>
