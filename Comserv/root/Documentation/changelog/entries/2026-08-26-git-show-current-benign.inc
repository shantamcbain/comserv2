<div id="2026-08-26-git-show-current-benign" class="cl-entry">
<h3>2026-08-26 — git branch --show-current no longer floods the error audit</h3>
<p class="doc-body"><strong>What.</strong> Prod1 logged ~39k ERROR todos for <code>git branch --show-current -&gt; exit=128</code> because every request (including bot <code>.php</code> probes) ran a live git overlay from <code>Root::auto</code> on an image with no <code>.git</code>.</p>
<p class="doc-body"><strong>Why.</strong> Production is image-only. That command failing is expected, not a git defect. It was logged at ERROR because the benign list covered only "no upstream" / worktree collision.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Git.pm</code> (skip <code>_run</code> when no <code>.git</code>; treat empty <code>--show-current</code> exit 128 as info). <code>lib/Comserv/Controller/Root.pm</code> (skip live overlay unless <code>.git</code> exists). Audit todos 2304/2300–2303 stay open until this image is on prod1 — closing them does not stop the storm.</p>
</div>
