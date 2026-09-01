<div id="2026-08-30-planning-todo-apptime" class="cl-entry">
<h3>2026-08-30 — Planning / Todo / Log clocks use AppTime</h3>
<p class="doc-body"><strong>What.</strong> Daily plan “today”, todo filters, work-log open/close, and API todo stamps no longer use bare <code>localtime</code> / host-local <code>DateTime->now</code>. They go through <code>Comserv::Util::AppTime</code>: UTC for stored log TIME and DATETIME stamps; viewer timezone for calendar “today” and form defaults. TT <code>| user_time</code> on todo/project posted timestamps.</p>
<p class="doc-body"><strong>Why.</strong> Docker (UTC) and workstation (PDT) disagreed on the same planning day and log durations; one clock system keeps DB rows comparable across hosts.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/AppTime.pm</code>, <code>Util/TodoLog.pm</code>, <code>Controller/{Planning,Todo,Log,Api}.pm</code>, <code>Model/Todo.pm</code>, <code>root/todo/*.tt</code>, <code>root/log/details.tt</code></p>
</div>
