<div id="2026-11-06-workday-standard" class="cl-entry">
<h3>2026-11-06 — Workday check for stale sessions, unclosed todos, and leftover Hermes</h3>
<p class="doc-body"><strong>What.</strong> <code>Comserv::Util::WorkdayStandard</code> reports open logs older than 12 hours, status-5 todos with no log row, Hermes processes, branch servers other than :4006, and old unmerged branch HEADs. <code>script/workday_standard.pl --check</code> is read-only. <code>--end-of-day</code> stops every other branch server and signals Hermes. It does not invent a log duration.</p>
<p class="doc-body"><strong>Why.</strong> A dashboard left up overnight holds the host lock, so the next open is observe-only. AI starts were left at status 5 with no log row, so the time was never recorded.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/WorkdayStandard.pm</code>, <code>Comserv/script/workday_standard.pl</code>, <code>Comserv/lib/Comserv/Controller/Api.pm</code>, <code>Comserv/root/Documentation/SessionWorkdayStandard.tt</code>.</p>
</div>
