<div id="2026-11-04-git-branch-server-units-and-post-merge-restart" class="cl-entry">
<h3>2026-11-04 — One systemd unit per worktree; bulk update never restarts a server by itself</h3>
<p class="doc-body"><strong>Why.</strong> Every branch server except :4006 runs as a hand-spawned
<code>perl script/comserv_server.pl -p &lt;port&gt; -r</code>. When Catalyst's restarter wedges, the live listener is the OLD process:
on 2026-11-04 :4004 had been up since 16:02 and never reloaded a single <code>.pm</code> edit, so a brand-new route answered 404 while
the file was correct — changes looked applied but were not served.</p>
<p class="doc-body"><strong>What.</strong> <code>script/autostart/gen_branch_units.pl</code> reads
<code>root/config/worktrees.json</code> (single source of truth) and writes
<code>~/.config/systemd/user/comserv-&lt;key&gt;-&lt;port&gt;.service</code> for every worktree: correct
<code>WorkingDirectory</code>, no <code>-r</code> (supervised by <code>Restart=on-failure</code>), per-port log under
<code>~/.comserv/logs/</code>, and an <code>ExecCondition</code> that waits out a hand-started server holding the port so a restart is
never a silent skip. It only writes files and prints the <code>systemctl --user enable --now</code> lines; nothing is enabled or
started. <code>BranchServerControl</code> already prefers a unit when one matches (<code>unit_name()</code>), so Open/Stop/Restart on
the dashboard go through <code>systemd --user</code> once a port is migrated.</p>
<p class="doc-body"><strong>What was deliberately NOT built: an automatic restart after the bulk merge.</strong> That was implemented
first and removed the same day — restarting a branch server drops that port's open browser sessions and any Hermes/agent chat running
in it, so a bulk update must never restart servers on its own. Rows report whether a server was listening; restarting stays a human
action (Develop Servers card or <code>systemctl --user restart</code>).</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/script/autostart/gen_branch_units.pl</code> (new).</p>
<p class="doc-body"><strong>Verified.</strong> <code>perl -c</code> clean; 16 units generated and a sample inspected. Not enabled: each
port must be stopped first, since a hand-started server holds it.</p>
</div>
