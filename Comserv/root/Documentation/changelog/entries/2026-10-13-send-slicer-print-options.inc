<div id="2026-10-13-send-slicer-print-options" class="cl-entry">
<h3>2026-10-13 — Start Print sends the slicer's print options (colours, leveling, calibration, time-lapse)</h3>
<p class="doc-body"><strong>What.</strong> Start Print was broken: <code>send_command()</code>
called <code>_build_ams_settings()</code> and <code>_build_task_settings()</code>, but neither
sub existed, so every start died at runtime with "Undefined subroutine" (<code>perl -c</code>
does not catch that — the calls resolve at run time). Both subs are now implemented and
the start payload carries what Anycubic Slicer Next sends: <code>ams_settings</code>
(<code>use_ams</code> plus up to four <code>ams_box_mapping</code> entries mapping a model
paint colour onto a physical ACE slot) and <code>task_settings</code> (auto bed leveling,
vibration/resonance compensation, flow calibration, time-lapse, dry mode, AI and drying
defaults, skip-parts list).</p>
<p class="doc-body"><strong>Why.</strong> Without them the printer started a file with
filename only and never received the colour map or the pre-print steps, so the queue could
not reproduce a slicer send.</p>
<p class="doc-body"><strong>Defaults.</strong> Bed leveling, resonance compensation and
flow calibration default ON, exactly as the captured slicer payload had them. Time-lapse
defaults OFF — it needs the camera and slows the job. An empty colour map sends no
<code>ams_settings</code> at all, which keeps the plain filename-only start working.</p>
<p class="doc-body"><strong>UI.</strong> The Start Print popup in <code>/3d/queue</code>
gained a "Print options (same as the slicer)" section: four checkboxes and a four-row
colour → ACE slot table (colour picker plus slot 1–4, each row optional).</p>
<p class="doc-body"><strong>Files.</strong>
<code>lib/Comserv/Util/Printing3d/Adapter/Anycubic.pm</code> (both builders, JSON::PP
booleans), <code>lib/Comserv/Controller/PrinterLan.pm</code> (param → opts wiring,
logging), <code>root/3d/queue.tt</code> (popup controls).</p>
</div>
