<div id="2026-10-30-branch-server-systemd" class="cl-entry">
<h3>2026-10-30 — Branch Restart clears an orphan, then starts the user unit</h3>
<p class="doc-body"><strong>What.</strong> Develop Servers Stop and Restart now stop only <code>comserv_server.pl</code> on that branch's registered port, then start <code>comserv-&lt;branch&gt;-&lt;port&gt;.service</code> when that user unit exists.</p>
<p class="doc-body"><strong>Why.</strong> <code>systemctl --user restart</code> skipped while a Cursor-started server still held the port. The unit does not own that process, and its start condition refuses to run until the port is free.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/BranchServerControl.pm</code>, <code>root/static/js/git-dashboard.js</code>, <code>t/branch_server_control.t</code></p>
</div>
