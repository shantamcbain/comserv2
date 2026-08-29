<div id="2026-08-26-todolog-mysql-time-clamp" class="cl-entry">
<h3>2026-08-26 — clamp completed-log duration to MySQL TIME max</h3>
<p class="doc-body"><strong>What.</strong> <code>done_with_log</code> on todo 2103 failed with <code>Incorrect time value: '840:00:00' for column log.time</code> (audit todo 2312). The Done path with no open log wrote <code>estimated_man_hours * 60</code> into a MySQL TIME column.</p>
<p class="doc-body"><strong>Why.</strong> MySQL TIME max is 838:59:59. Estimate 840 hours overflowed and the INSERT was rejected, so Done did not stick.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/TodoLog.pm</code> (<code>_insert_completed_log</code> clamps minutes to 838:59).</p>
</div>
