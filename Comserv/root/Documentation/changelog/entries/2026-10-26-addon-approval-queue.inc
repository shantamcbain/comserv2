<div id="2026-10-26-addon-approval-queue" class="cl-entry">
<h3>2026-10-26 — CSC add-on approval queue</h3>
<p class="doc-body"><strong>What.</strong> Subscribe no longer enables a site module. <code>/membership/addons</code> does not write <code>site_modules.enabled</code>. A CSC admin approves a named site (3d, CSC, or Shanta) from <code>/admin/site_modules/approval_queue</code>.</p>
<p class="doc-body"><strong>Why.</strong> A site admin could turn on their own add-on, and saving add-ons on the CSC host wrote CSC instead of the site that subscribed. Accounting still requires <code>enabled=1</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Membership.pm</code>, <code>Controller/Admin/SiteModules.pm</code>, <code>membership/Addons.tt</code>, <code>admin/site_modules/approval_queue.tt</code>.</p>
</div>
