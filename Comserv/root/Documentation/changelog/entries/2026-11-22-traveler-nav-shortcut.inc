<div id="2026-11-22-traveler-nav-shortcut" class="cl-entry">
<h3>2026-11-22 — Chat can open the Manufacturing traveler</h3>
<p class="doc-body"><strong>What.</strong> Chat-with-AI now has a built-in "Manufacturing Traveler" shortcut to <code>/Accounting/manufacturing</code> (triggers include "traveler" and "open traveler") when no database shortcut already covers it. Logged-in users see it; guests do not. The accounting page still checks admin / site_admin / accounting role.</p>
<p class="doc-body"><strong>Why.</strong> HelpDesk CSC-20260914-6545. There were no traveler rows in the AI navigation shortcuts table, so the assistant said the page was unknown.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Navigation.pm</code>, <code>t/navigation_link_visibility.t</code></p>
</div>
