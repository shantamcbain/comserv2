<div id="2026-09-19-hardware-monitor-full-deployment" class="cl-entry">
<h3>Hardware Monitor: Full device deployment + NFS log cleanup</h3>

<p><strong>Date:</strong> 2026-09-19</p>

<h4>device_agent.sh deployed to all 5 monitored devices</h4>
<ul>
  <li>Each host runs a 5-min cron collecting disk, CPU, memory, temp, uptime
      and POSTs to <code>/admin/hardware_monitor/ingest</code> with the shared token.</li>
  <li><strong>workstation</strong> (.199) — root, installed to /usr/local/bin/</li>
  <li><strong>proxmox720</strong> (.2) — root, installed to /usr/local/bin/</li>
  <li><strong>gateway/proxmoxt210</strong> (.3) — root, installed to /usr/local/bin/</li>
  <li><strong>comserv</strong> (.198) — shanta, installed to ~/bin/</li>
  <li><strong>nfs/sunfire</strong> (.175) — shanta, installed to ~/bin/</li>
</ul>

<h4>Old DBI hardware_monitor.pl scripts replaced</h4>
<ul>
  <li><strong>.2 (proxmox720):</strong> Replaced 12KB DBI script with thin trigger.
      Seeded /usr/local/etc/comserv/hw_ingest_token file.</li>
  <li><strong>.198 (comserv):</strong> Replaced 11KB DBI script with thin trigger + token baked in cron.</li>
  <li>Both now point at .126:5000 and .199:5000 with the real shared token. Old bare
      <code>perl script.pl</code> cron lines that generated mail errors removed.</li>
</ul>

<h4>Workstation monitoring fixed</h4>
<ul>
  <li>Created /usr/local/etc/comserv/hw_ingest_token from NFS source of truth.</li>
  <li>Copied thin hardware_monitor.pl to /usr/local/bin/.</li>
  <li>Crontab rewritten with real token (reads NFS first, local fallback).</li>
</ul>

<h4>Watchdog verified green</h4>
<ul>
  <li>Returns <code>missed:0, age_sec:&lt;real&gt;, ok:1</code> after fix.</li>
  <li><code>/admin/hardware_monitor/run</code> returns HTTP 200 on both :5000 containers
      (.199 and .126).</li>
</ul>

<h4>NFS disk cleanup</h4>
<ul>
  <li>Removed 37G of old workshop logs (June 2026) from /home/shanta/nfs/comserv-workshop/logs/archive/.</li>
  <li>Removed 17G of rotated application.log archives (Aug-Sep) from /home/shanta/nfs/logs/archive/.</li>
  <li>Removed 8.9G of old catalyst_error logs (March 2026) from /home/shanta/nfs/comserv/logs/.</li>
  <li>Total freed: ~63G. NFS now at 62% (1.1T/1.8T).</li>
</ul>

<h4>Health controller bug closed</h4>
<ul>
  <li>Root cause: <code>Comserv->json->encode(...)</code> called non-existent method on Comserv package.
      Fixed in commit 2eb488568 (Sep 12) — replaced with <code>encode_json()</code> from JSON::MaybeXS.</li>
  <li>Stale error todos #2439, #2440, #2441 ready to close.</li>
</ul>
</div>