<div id="2026-11-12-origin-check-shared" class="cl-entry">
<h3>2026-11-12 — Shared same-origin check for state-changing POSTs</h3>
<p class="doc-body"><strong>What.</strong> New <code>Comserv::Util::OriginCheck</code>: every Origin/Referer header present must parse as <code>scheme://host[:port]</code> and match the request's canonical scheme, host and effective port. Absent, <code>null</code> or malformed headers are refused, so the check fails closed. <code>X-Forwarded-Proto</code>/<code>X-Forwarded-Port</code> are honoured only when the direct peer is a trusted proxy (<code>Comserv::Util::ClientIP</code>). <code>Calendar.pm</code>'s private <code>_same_origin</code>/<code>origin_ok</code> replaced by this helper.</p>
<p class="doc-body"><strong>Why.</strong> The calendar check compared host only: a request from <code>http://host:8080</code> to <code>https://host</code> passed, and the helper could not be reused by the other controllers that also POST.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/OriginCheck.pm</code> (new), <code>lib/Comserv/Controller/Calendar.pm</code>.</p>
</div>
