<div id="2026-08-29-api-todo-done-with-log-time-clamp" class="cl-entry">
<h3>2026-08-29 — Api todo done_with_log clamp for absurd estimated_man_hours</h3>
<p class="doc-body"><strong>What.</strong> In <code>Util::TodoLog::_insert_completed_log</code>, the no-open-log fallback path used <code>estimated_man_hours * 60</code> directly for the <code>log.time</code> column (MySQL TIME). Todo 2103 had <code>estimated_man_hours=840</code>, producing <code>'840:00:00'</code> which exceeds the 838:59:59 limit and caused DBI insert failure (audit todo 2312, triggered via <code>Api::api_todo_done_with_log</code>).</p>
<p class="doc-body"><strong>Why.</strong> The graceful "insert a completed log when none is open" path had no sanity cap on the source data. A previous clamp attempt left dead code and still trusted the potentially-huge estimated value.</p>
<p class="doc-body"><strong>Fix.</strong> Added early sane-default guard (cap anything &gt;8h to 30 min) before the existing 838h59m clamp. Removed dead <code>_duration_hms</code> call whose result was overwritten. Source now compiles cleanly; error path cannot produce invalid TIME again.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/TodoLog.pm:67-77</code></p>
</div>
