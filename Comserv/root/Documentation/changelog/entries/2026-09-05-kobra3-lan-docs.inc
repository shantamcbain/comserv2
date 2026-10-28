<div id="2026-09-05-kobra3-lan-docs" class="cl-entry">
<h3>2026-09-05 — Docs: Kobra 3 LAN state matches code</h3>
<p class="doc-body"><strong>What.</strong> Rewrote <code>Kobra3LanMode.tt</code> to the live protocol (discover 1–254, <code>[LAN_HOST]</code> attach, GET /info identity, signed /ctrl, MQTTS telemetry, control page). Coordinator <code>3dPrintingPlan.tt</code> Now block, child-plan row, tracking row, and <code>#lan</code> section. Changelog fragments already record the code. Do not edit root CHANGELOG.tt.</p>
<p class="doc-body"><strong>Why.</strong> Next session must not restart from “scan 50–200 / add a new farm row / Docker MQTT sidecar”. Linked printer is 192.168.2.53; remaining work on todo #2334 is queue Complete from printer time, not rediscovery.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/Documentation/3d/Kobra3LanMode.tt</code>, <code>root/Documentation/3dPrintingPlan.tt</code>.</p>
</div>
