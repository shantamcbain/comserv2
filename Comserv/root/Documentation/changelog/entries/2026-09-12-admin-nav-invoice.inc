<div id="2026-09-12-admin-nav-invoice" class="cl-entry">
<h3>2026-09-12 — Admin Navigation: Invoice Classification</h3>
<p class="doc-body"><strong>What.</strong> Moved invoice classification links from Main nav to admin-only locations: admintopmenu.tt (Admin dropdown submenu) and admin/index.tt (Accounting card). Added "Mail Invoice Classification" and "Sort Invoices by Site" links.</p>
<p class="doc-body"><strong>Why.</strong> Admin-only routes should be in admin navigation, not the main user dropdown. The admin Accounting card is the appropriate location since invoice classification is an accounting workflow.</p>
<p class="doc-body"><strong>Files.</strong> <code>Navigation/admintopmenu.tt</code> — added invoice links to admin submenu. <code>admin/index.tt</code> — added Mail Invoice Classification and Sort Invoices links to Accounting card. <code>Navigation/TopDropListMain.tt</code> — removed links from Main nav. Changelog fragment added.</p>
</div>
